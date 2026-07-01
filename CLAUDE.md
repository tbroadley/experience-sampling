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
  always empty — the per-pomodoro goal feature was removed)
- `anthropic-api-key.txt` - Claude API key for the focus coach
- `todoist-api-token.txt` - Todoist API token (set in Settings → Focus)
- `focus-log.jsonl` - one line per focus check; `task` holds the top to-do at that time
- `meeting-attention-log.jsonl` - one line per meeting-drift nudge (`context`, `linger_seconds`)

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

## Focus Coach & Todoist

The focus coach no longer uses a manually-set pomodoro goal. Instead, on every
focus check it fetches the user's **top Todoist to-do for today** (lowest
`day_order` among incomplete tasks due on or before today — overdue included) via
the Todoist Sync API (`POST /api/v1/sync`, `resource_types=["items"]`) and keeps
the user on that. This is the same `day_order` field the `tbroadley/status-dashboard`
app persists when you reorder todos, so the two stay in sync through Todoist itself
(no direct coupling). When there is no to-do for today, the coach prompts the user
to create one and can add it via the `create_todo` tool (`POST /api/v1/tasks`).

The Claude model used for both classification and coaching is configurable in
Settings → Focus (`focusModel` in `UserDefaults`, defaults to
`FocusMonitor.defaultModel` = `claude-sonnet-5`). `FocusMonitor.model` reads it
and both API calls (`callClassifyAPI`, `callAPIWithTools`) use it.

## Gotchas

- **JSON date encoding/decoding must match**: When using `JSONEncoder` with `.iso8601` date strategy, the corresponding `JSONDecoder` must also use `.iso8601`. The default decoder strategy (`.deferredToDate`) expects a `Double`, not an ISO 8601 string, and `try?` silently swallows the mismatch — causing data loss on reload.
- **`try?` can hide data-destroying bugs**: The `load()` methods use `try?` to decode JSON. If decoding fails silently, the in-memory array resets to `[]`, and the next `save()` overwrites the file. Be careful when changing encoding strategies or data models.
