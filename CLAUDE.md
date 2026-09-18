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

- UI and application logic: `ExperienceSampling/ExperienceSampling.swift`
- S3 transport and conditional writes: `ExperienceSampling/TaskStorage.swift`
  - Entry point is an `@main struct` guarded by `#if !TESTING`; the app builds
    with `-parse-as-library` so `@main` is valid in a lone file.
- App bundle info: `ExperienceSampling/Info.plist`
- Installed location: `/Applications/ExperienceSampling.app`
- Tests: `ExperienceSamplingTests/main.swift`, run via `run-tests.sh`

## Fifth-pomodoro sound

Finishing the **fifth** completed pomodoro of a day plays a celebration sound.
The check lives in the `onWorkSessionEnd` handler (`playMilestoneSoundIfDue`),
which runs after the session is marked completed, so the just-finished pomodoro
is already in `PomodoroDataStore.completedTodayCount(workDuration:)` — the same
full-length-only count the menu shows, so a pomodoro cut short by a meeting
doesn't earn the sound. It compares with `==`, not `>=`, so it fires once a day
rather than on every pomodoro from the fifth on.
The `NSSound` is retained in a property — a deallocated `NSSound` stops
mid-playback.

The audio file is **not in the repo and not in the app bundle** (this repo is
public and the recording is personal). It's read at
`~/Library/Application Support/ExperienceSampling/fifth-pomodoro.mp3`, alongside
the data stores; override with `defaults write org.metr.ExperienceSampling
milestoneSoundPath /path/to.mp3`. A missing or unplayable file just means no
sound, but it's logged to `coach-errors.log` rather than passing silently.

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
- Task data is in the configured S3 object; the AWS CLI owns credentials.
  No task credentials or infrastructure identifiers are bundled.
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

`CalendarMonitor` reads today's primary-calendar events through `CalendarCLI`.
It is the only consumer of `gws`; task storage uses AWS independently. Events
drive meeting detection, meeting-aware pomodoro capping, and Meet-link opening.

Request only Calendar read access:

```bash
gws auth login --scopes https://www.googleapis.com/auth/calendar.readonly
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
- `CalendarMonitor.calendarError(from:)` distinguishes expired logins from
  missing Calendar permissions by the error detail. Task errors never trigger
  Google sign-in.
- The `.gwsSignIn` action requests `calendar.readonly` explicitly and deletes
  `token_cache.json` only after successful authorization. Never restore the old
  multi-service grant.
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

The task list is an **S3 JSON document** shared with `tbroadley/status-dashboard`.
`TasksClient` keeps task-selection semantics; `S3TaskStore` handles storage.
Reordering in the dashboard updates the same document the coach reads.

- Version 1 wire format: `{"version":1,"rows":[...]}`, nine string cells per row:
  `id, content, project, description, due, recurrence, order, done, completed_at`.
- `TaskConfiguration` resolves app settings, then environment, then the shared
  dashboard env file. See README for `TASKS_S3_URI`, optional AWS region/CLI, and
  UserDefaults keys. Never commit real locations, identifiers, credentials, or tasks.
- Reads validate the schema and require an ETag. Missing/invalid documents fail
  closed; initialization is an explicit create-only operation in `task-store`.
- Appends preserve a pre-edit recovery object under `<key>.history/`, then use
  `If-Match`. Conflicts reread/reapply up to three attempts. Backup failure aborts
  the edit. Network/auth failures are visible; there is no offline write queue.
- The AWS CLI owns credentials. `TaskCommand` uses private temporary files and
  a process deadline; errors omit raw AWS output and private locations.
- Completing recurring tasks in the dashboard advances the due date instead of
  setting `done`, so they retain the existing completed-today behavior.
- `CalendarCLI` still finds `gws` by absolute path and leads PATH with its
  directory so nvm-installed Node can run. It has no task-storage role.

**Task-list failures are loud too.** No to-do means no check at all, so a dead
token silently killed the whole coach for days (it looked identical to a coach
with nothing to say — the exact failure mode this design exists to prevent).
`TopTodo.unavailable` now carries a `CoachError` — `tasksNotConfigured` /
`tasksAuthRequired` (AWS sign-in needed) / `tasksUnavailable` (AWS CLI missing,
S3 request failed, or invalid document) — into the same log + modal + menu-bar path as the Claude
errors. `CoachError.fixAction` picks the modal's button: Hawk errors get "Sign in
to Hawk", missing task configuration gets "Open Settings".

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
