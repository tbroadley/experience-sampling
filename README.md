# Experience Sampling

[![CI](https://github.com/tbroadley/experience-sampling/actions/workflows/ci.yml/badge.svg)](https://github.com/tbroadley/experience-sampling/actions/workflows/ci.yml)

A macOS menu-bar app for experience sampling, pomodoro sessions, and a focus coach with an S3-backed task list.

## Task storage and Calendar

Tasks are stored in a shared S3 JSON document, not in Google Sheets. Set
`TASKS_S3_URI` in `~/.config/status-dashboard/.env` (or under `XDG_CONFIG_HOME`),
or enter the object URI in Settings → Focus (`tasksS3URI` in UserDefaults).
Optional `TASKS_AWS_REGION` and `TASKS_AWS_CLI` select a region and AWS CLI binary;
the corresponding UserDefaults keys are `tasksAWSRegion` and `awsPath`.
App settings take precedence over environment variables, then the shared env
file. No bucket, key, account, or user identifier is built into the app.

Use a current AWS CLI supporting conditional S3 writes and sign in through its
normal credential chain (`aws sso login` for SSO). The configured prefix must
allow reads/writes and any encryption-key access required by its bucket.
Privacy is enforced by your bucket/IAM configuration, not by this app.

The wire format is `{"version":1,"rows":[...]}`. Each row has nine strings:
`id, content, project, description, due, recurrence, order, done, completed_at`.
The app shares this format with status-dashboard. Create/import the document
explicitly using its `task-store init-empty` or `task-store import-csv` tool;
missing or corrupt objects never silently initialize an empty list.

Appending a task archives the previous document under `<key>.history/` and uses
an ETag conditional write, retrying conflicts without losing another client's
edits. A failed archive prevents the write. Lost write responses are checked by
reading back the document; unresolved outcomes warn to check the list before
retrying. S3 is the source of truth: edits
require connectivity and valid credentials, with no offline queue. Reconfigure
the same URI after disk failure; restore older snapshots with status-dashboard's
`task-store restore` command. Bucket versioning is also recommended.

`gws` is used **only for Calendar**. Re-authorisation requests exactly Calendar
read access (plus basic Google sign-in identity), and clears stale access tokens
only after a successful login:

```bash
gws auth login --scopes https://www.googleapis.com/auth/calendar.readonly
```

## Dropdown behavior

The timer section shows exactly one control:

| Timer state | Control | Effect |
| --- | --- | --- |
| Idle, including a snoozed next pomodoro or calendar-deferred restart | Start Pomodoro | Starts work immediately, with the usual duration caps |
| Work running | Abandon Pomodoro | Stops work and records it as incomplete |
| Work completed; break prompt open or snoozed | Take Break Now | Starts the short/long break due in the cycle |
| Short or long break | End Break | Ends the break early and follows the normal next-pomodoro prompt flow |

Ending a break never changes the completed work session. The next-pomodoro
prompt still respects meetings and working hours; it does not auto-start work.
Restored timers use the same controls. There is no paused-timer state.

The other dropdown entries are:

- **Check in now** — available in every state, including outside sampling hours.
  Automatic check-ins still follow the schedule and weekend quiet policy.
- **Top to-do** — read-only; shown only during active work when a task is known.
- **Pomodoros completed today** — always shown, read-only. Completed sessions
  started today count if their planned duration is at least 90% of the configured
  work duration (45–50 minutes for a 50-minute setting). Longer sessions and older
  records without a planned duration still count; abandoned sessions do not.
- **Coach/calendar warning** — shown only while an error is pinned; opens its
  explanation and recovery actions in any timer state.
- **View History**, **Pomodoro History**, **Export Data…**, **Settings…**, and
  **Quit** — available in every state. Export Data exports check-in responses.
- **Debug** — diagnostic commands remain available; Show Pomodoro Start is
  disabled while a timer or another pomodoro-start/break prompt is active.

## Fifth-pomodoro sound

The fifth qualifying pomodoro of the day plays
`~/Library/Application Support/ExperienceSampling/fifth-pomodoro.mp3`.
The sound uses the same 90%-duration threshold as the daily menu count and
plays at most once per day, including across restarts and later short sessions.
The recording is local only, never bundled or committed. Override its location
with `defaults write org.metr.ExperienceSampling milestoneSoundPath /path/to.mp3`.

Use **Debug → Test Milestone Sound** to check playback without changing your
session count or consuming the milestone. Playback starts, missing files, and
playback failures are recorded in `coach-errors.log`.

## Development

The UI and coach live in `ExperienceSampling/ExperienceSampling.swift`;
`ExperienceSampling/TaskStorage.swift` contains the S3 document and CLI transport.
See [CLAUDE.md](CLAUDE.md) for architecture notes and gotchas.

```bash
./rebuild-and-restart.sh   # typecheck, lint, rebuild, codesign, install, restart
./run-tests.sh             # headless logic tests
swiftlint lint --strict    # lint (config in .swiftlint.yml)
```

The rebuild script stamps the Git revision and whether the worktree is modified
into the installed bundle. **Debug → Build** and the launch entry in
`coach-errors.log` identify the running build. Builds without metadata show
`Build: unknown`. To inspect the full installed revision:

```bash
/usr/libexec/PlistBuddy -c 'Print :ExperienceSamplingGitCommit' \
  /Applications/ExperienceSampling.app/Contents/Info.plist
```

The script refreshes `Info.plist` from source, waits for the old process to exit,
verifies the installed binary and signature, and fails if the new app is not
running after restart. Building from a clean, up-to-date `main` gives an
unmodified revision that can be compared directly with `git rev-parse HEAD`.

## CI

[GitHub Actions](.github/workflows/ci.yml) runs on every push to `main` and on
PRs, on a `macos-26` runner (matching the macOS version the app ships on):

- **test** — typechecks the app and runs the headless logic tests.
- **lint** — runs SwiftLint in `--strict` mode.
