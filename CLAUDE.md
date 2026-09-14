# Experience Sampling App

## Build, Codesign, and Restart

After making changes to the Swift code, use the rebuild script:

```bash
./rebuild-and-restart.sh
```

`rebuild-and-restart.sh` handles typecheck, optional linting, rebuild, codesign, install, and app restart. The certificate name is configured in `.env`.

## Tests

```bash
./run-tests.sh
```

Headless logic tests for `PomodoroScheduler` (wall-clock timer / restore, snooze
state). The test file (`ExperienceSamplingTests/main.swift`) is compiled together
with the app source under `-DTESTING`, which strips the app's `@main` entry point
so the test file owns `main`. The binary is codesigned (Santa blocks unsigned
binaries) and run with `CFFIXED_USER_HOME` pointed at a temp dir so the data
stores never touch real data. Exit code is non-zero on any failure.

## Project Structure

- Single-file Swift app: `ExperienceSampling/ExperienceSampling.swift`
  - Entry point is an `@main struct` guarded by `#if !TESTING`; the app builds
    with `-parse-as-library` so `@main` is valid in a lone file.
- App bundle info: `ExperienceSampling/Info.plist`
- Installed location: `/Applications/ExperienceSampling.app`
- Tests: `ExperienceSamplingTests/main.swift`, run via `run-tests.sh`

## Data Storage

Data is stored in `~/Library/Application Support/ExperienceSampling/`:
- `responses.json` - Experience sampling responses
- `pomodoro-sessions.json` - Pomodoro session history (`taskDescription` is now
  always empty — the per-pomodoro goal feature was removed). `plannedMinutes`
  records the length the session was *started* with; meeting- and
  workday-aware capping can start one shorter than `pomodoroWorkDuration`, and
  sessions at least 90% of the configured duration count in the "completed today"
  menu total (`completedTodayCount(workDuration:)`), so 45–50 minutes count for
  a 50-minute setting. Shorter sessions and abandoned work don't. It's optional:
  sessions written before the field existed decode as `nil` and still count.
- (no task credentials: the Google Sheet task list is reached via the `gws` CLI,
  which owns its own auth. A leftover `todoist-api-token.txt` is dead.)
- `focus-log.jsonl` - one line per focus check; `task` holds the top to-do at that time
- `coach-errors.log` - one line per focus-coach diagnostic (auth/network/HTTP failures,
  retries, recoveries). Also mirrored to the unified log with an `[FocusCoach]` prefix.
  There is no longer an `anthropic-api-key.txt`; see "Focus coach auth" below.
- `meeting-attention-log.jsonl` - one line per meeting-drift nudge (`context`, `linger_seconds`)

## Pomodoro dropdown

The timer control is a single menu item selected by `PomodoroMenuAction`:
idle → Start Pomodoro, active work → Abandon Pomodoro, completed work awaiting
its break (including snoozed) → Take Break Now, either break → End Break.
`phase == .work && timeRemaining == 0` means completed work awaiting a break,
including on restore; it must not be abandoned or restarted as active work.
`endBreak()` uses the normal break-end callback and leaves session history alone.
Menu actions dismiss superseded next-work/break prompts without re-snoozing them.
See the README for the full dropdown inventory.

## Weekend Quiet Mode

`PromptPolicy` (pure, unit-tested) gates the two self-report modals. With
`weekendQuietMode` on (default; Settings → Sampling):

- the start-of-day "How excited are you to work today?" prompt never fires on a
  Saturday/Sunday — a pomodoro can still be started from the menu;
- random intraday check-ins fire on a weekend only when a pomodoro is running
  **or** the user is present (screen unlocked and HID input within
  `PromptPolicy.activityWindow`, 5 min).

A suppressed weekend check-in is *dropped*, not snoozed. That's deliberate:
snoozing re-arms the prompt every 5 minutes, which is how an unattended weekend
used to build a stack of modals waiting on Monday.

## Calendar

`CalendarMonitor` reads today's primary-calendar events through the same `gws`
CLI as the task list (`TasksClient.runGws`), so both share one Google auth and
one binary lookup. Events drive meeting detection, meeting-aware pomodoro
capping, and auto-opening a Meet link 60s before a call.

**This needs the `calendar` OAuth scope**, which `gws auth login` does *not*
grant by default. Re-grant without dropping the scopes the coach needs:

```bash
gws auth login --services drive,gmail,sheets,docs,calendar
```

A missing scope comes back as HTTP 403 `insufficientPermissions` **in the
response body with a zero exit code**, so it's caught from `json["error"]`, not
the exit status. Two traps:

- gws caches the access token in `~/.config/gws/token_cache.json`, and that cache
  **outlives a re-login** — after adding a scope you may need to delete it, or
  calls keep 403ing with the old token even though `gws auth status` shows the
  new scope.
- Calendar failures used to be silent (`refresh()` just `return`ed), and an empty
  calendar is indistinguishable from a broken one: no nudges, no capping, no
  Meet links, no trace. Failures now go to `coach-errors.log` via
  `CoachLog.record(_:context:)`, logged once per error kind with a matching
  "calendar recovered" line — **and** onto the same modal + pinned menu-bar row
  as the coach errors (`CalendarMonitor.onError` → `showCoachError`), throttled
  per kind by `CoachErrorThrottle`. Logging alone wasn't enough: a missing
  `calendar` scope once sat in the log for twelve days because nothing the user
  could see changed.
- `CalendarMonitor.calendarError(from:)` re-labels the generic `TasksClient`
  failure as `calendarAuthRequired` / `calendarScopeMissing` /
  `calendarUnavailable`. Two reasons it can't just pass the tasks error through:
  the modal would say "can't read the task sheet" for an OAuth problem, and
  `runGws` classifies a 403 as `tasksAuthRequired` (`looksLikeAuthFailure`
  matches `"403"`), so the scope case has to be recognised from the *detail
  text* — `looksLikeMissingScope` — not the error case.
- The `.gwsSignIn` fix action runs
  `gws auth login --services drive,gmail,sheets,docs,calendar` in Terminal via a
  `.command` file (no Automation permission) **and deletes `token_cache.json`**.
  Don't drop either half: a bare `gws auth login` re-grants without calendar, and
  the cache outlives the re-login, so skipping the delete makes a correct
  re-grant still 403.
- The pinned menu-bar row is shared, so both recovery handlers check the
  `calendar-` kind prefix before clearing it. Without that, a coach recovery
  wipes a still-valid calendar warning and vice versa.

## Meeting Attention

`MeetingAttentionMonitor` nudges the user back when they drift away from a live
meeting. "In a meeting" = mic/camera active **AND** a real meeting context: a
current calendar **video** meeting (`isInScheduledMeeting`, wired to
`CalendarMonitor.isInVideoMeeting()` — only events with a Meet/conference link
count, so "Lunch"/phone-appointment blocks don't) **or** an open Meet/Teams/Zoom
call (`meetingCallOpen()`). The AND is essential —
mic-alone is not enough because Wispr Flow dictation also holds the mic; the calendar
/ call check is what excludes dictation. The call probe checks native call apps via
the Accessibility API (`callApps`, e.g. Zoom's "Zoom Meeting" window) and browser
tabs via AppleScript (`meetingURLMarkers` across Chromium browsers + Safari; one-time
Automation permission per browser). It's throttled (`contextRefreshInterval`, 20s)
and only runs while AV is active, so dictation doesn't pay for it constantly.
A drift = lingering past a threshold
(default 25s) on something that isn't allowlisted. The browser is special-cased:
it counts as "on the meeting" only while its focused-window title looks like a
meeting tab (Meet/Zoom/Webex) — otherwise switching browser tabs reads as a drift.
The nudge offers "Back to the meeting" (re-arm) or "I'm here on purpose" (mute for
the rest of this meeting). Decision logic lives in the pure `classify`/`step`
methods so it's unit-tested headlessly (see `run-tests.sh`). Settings → Meetings
tab toggles it and edits the threshold/allowlist; window-title reads need
Accessibility permission (without it the browser never counts as a drift).

## Focus Coach & the task list

The focus coach no longer uses a manually-set pomodoro goal. Instead, on every
focus check it fetches the user's **top to-do for today** — lowest `order` among
incomplete tasks due on or before today (overdue included) — and keeps the user
on that. When there is no to-do for today, the coach prompts the user to create
one and can add it via the `create_todo` tool.

The task list is a **Google Sheet**, read through the `gws` CLI (`TasksClient`).
It replaced Todoist in Aug 2026, following `tbroadley/status-dashboard`, which
made the same switch in its `clients/sheets.py` — this app deliberately mirrors
that module's semantics so the two share one list with no direct coupling.
Reorder in the dashboard and the coach follows.

- Sheet layout, row 1 a header:
  `A id | B content | C project | D description | E due | F recurrence | G order | H done | I completed_at`
- `gws` owns the Google auth, so there is **no token on disk** for this app.
  (The old `todoist-api-token.txt` is dead; safe to delete.)
- The sheet ID is **not hardcoded** — this repo is public. It comes from
  `defaults write org.metr.ExperienceSampling tasksSpreadsheetId <id>`, falling
  back to `TASKS_SPREADSHEET_ID` in `~/.config/status-dashboard/.env`, which
  status-dashboard already maintains. Editable in Settings → Focus.
- `gws` is found by absolute path (a GUI app has a bare `PATH`), including a scan
  of `~/.nvm/versions/node/*/bin` since nvm moves it on every Node upgrade;
  override with `defaults write org.metr.ExperienceSampling gwsPath`.
  Finding `gws` is only half of it: it's a Node script with a
  `#!/usr/bin/env node` shebang, so `env` has to find `node` too. `runGws`
  therefore runs it with a `PATH` led by gws's own directory (for an nvm install
  that's where its matching node lives) — without that the call fails as
  `gws sheets exited 127: env: node: No such file or directory`.
- Completing a **recurring** task rolls its due date forward instead of setting
  `done`, so recurring work never shows up in "completed today".

**Task-list failures are loud too.** No to-do means no check at all, so a dead
token silently killed the whole coach for days (it looked identical to a coach
with nothing to say — the exact failure mode this design exists to prevent).
`TopTodo.unavailable` now carries a `CoachError` — `tasksNotConfigured` /
`tasksAuthRequired` (gws can't reach Google) / `tasksUnavailable` (gws missing,
API error, unparseable) — into the same log + modal + menu-bar path as the Claude
errors. `CoachError.fixAction` picks the modal's button: Hawk errors get "Sign in
to Hawk", a missing sheet gets "Open Settings".

**Never-off-task screens.** `classifyUserPrompt` carries an explicit exception
list to its own "be strict" rule, covering the screens that generated most of the
false positives in `focus-log.jsonl`: sign-in/SSO pages (the cloud access portal,
Workspace verification, MFA prompts), the status dashboard (which *is* the to-do
list this coach reads), empty transitions ("New Tab"/"Untitled"/loading), live
calls (Meet/Zoom/Teams/Slack huddles), and the calendar. Each entry says why it is
instrumental, because a bare list of window titles doesn't generalise. The prompt
also tells the model to judge the screen *before* one of these rather than
treating it as a reset, so an SSO tab can't launder a real distraction. The list
lives in the classifier prompt, not in a code-side allowlist, so follow-up checks
(which share `classifyUserPrompt`) get it too.

The Claude model used for both classification and coaching is configurable in
Settings → Focus (`focusModel` in `UserDefaults`, defaults to
`FocusMonitor.defaultModel` = `claude-sonnet-5`). `FocusMonitor.model` reads it
and both API calls (`callClassifyAPI`, `callAPIWithTools`) use it.

## Focus coach auth (Middleman + Hawk)

Claude is reached through METR's Middleman proxy, **not** api.anthropic.com, and
there is no API key on disk any more. `MiddlemanClient` posts to
`<proxy-base-url>/anthropic/v1/messages` — Anthropic's native
Messages API re-exposed verbatim, so request/response bodies are unchanged.

The proxy host is **not** hardcoded: this repo is public and the hostname isn't.
It is resolved at runtime from `defaults write org.metr.ExperienceSampling
middlemanBaseURL <url>`, falling back to `HAWK_MIDDLEMAN_URL` in
`~/.config/hawk-cli/env` (which hawk maintains, so a working hawk install needs no
extra setup). With neither, calls fail as `proxy-not-configured`. Don't reintroduce
a default hostname in source.

Auth
is `x-api-key: <hawk access token>` plus `anthropic-version: 2023-06-01`. Note the
header: Middleman's `/openai/...` passthrough wants `Authorization: Bearer`, but
the `/anthropic/...` one wants `x-api-key`.

`HawkAuth` mints the token by shelling out to `hawk auth access-token`. hawk owns
the whole OAuth story (the refresh token lives in the login keychain under
`hawk-cli:<clientID>`, which only hawk's own binary has an ACL for), and refreshes
silently when the access token is expiring — so automatic refresh is just "run
hawk again". A non-zero exit means a real browser login is needed; that's the
`invalid_grant` case. The token is cached in memory until 2 minutes before the
JWT's `exp`. hawk is looked up by absolute path (`~/.local/bin/hawk`, Homebrew,
`/usr/local/bin`) because a GUI app inherits a bare `PATH`; override with
`defaults write org.metr.ExperienceSampling hawkPath /path/to/hawk`.

**Failures are loud, never silent.** This is the whole point of the design: the
old code collapsed every failure into `completion(nil)`, which made `classify`
default to `on_task: true` with an empty message — a dead API key looked exactly
like being on task. Now every failure becomes a `CoachError`
(`hawkMissing` / `notAuthenticated` / `tokenRejected` / `networkUnavailable` /
`modelNotEntitled` / `httpError` / `badResponse`), which is:

- logged to `coach-errors.log` **always**,
- shown as a `CoachErrorView` modal with an actionable message and a "Sign in to
  Hawk" button (which opens Terminal on `hawk auth login` via a `.command` file,
  so no Automation permission is needed),
- pinned to a menu-bar row that stays until a call succeeds,
- throttled per error kind (`CoachErrorThrottle`, 10 min) so a sustained outage
  doesn't stack a modal on every 30s check; any success resets the throttle.

Transient failures (network, 408/429/5xx) retry up to 3 attempts with 2s/6s
backoff. Auth failures never retry in a loop — except a 401, which re-mints the
token once (it may just be one we cached a moment too long) before giving up.

Verify the whole chain end to end with **Debug → Test Coach Connection**, or
headlessly with `open "experiencesampling://test-coach"` and then
`tail ~/Library/Application\ Support/ExperienceSampling/coach-errors.log`. To
exercise the failure paths, point `hawkPath` at a script that exits non-zero (→
`notAuthenticated`) or prints a junk JWT (→ `tokenRejected`), set `focusModel` to
a model Middleman lists but isn't entitled to (→ `modelNotEntitled`), or set
`defaults write org.metr.ExperienceSampling middlemanBaseURL <unreachable-host>`
(→ `networkUnavailable` plus the backoff path).

Note on `max_tokens`: it is a budget for thinking **and** text. Sonnet 5 emits a
`thinking` block first, and it routinely runs 150-400 tokens even for "ping"; if
the budget runs out inside it, the reply comes back `stop_reason: max_tokens`
with a thinking block and no text at all. That was the cause of the intermittent
"classification response had no text block" errors — the default was 300, and a
real classification prompt regularly thought past it. The default is now 2000 and
the connection probes use 512. Both call sites read the *first text block* rather
than `content.first`, so a leading thinking block isn't itself a failure, and the
classify error detail now includes `stop_reason` and the block types.

## Gotchas

- **JSON date encoding/decoding must match**: When using `JSONEncoder` with `.iso8601` date strategy, the corresponding `JSONDecoder` must also use `.iso8601`. The default decoder strategy (`.deferredToDate`) expects a `Double`, not an ISO 8601 string, and `try?` silently swallows the mismatch — causing data loss on reload.
- **`try?` can hide data-destroying bugs**: The `load()` methods use `try?` to decode JSON. If decoding fails silently, the in-memory array resets to `[]`, and the next `save()` overwrites the file. Be careful when changing encoding strategies or data models.
