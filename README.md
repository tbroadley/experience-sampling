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
edits. A failed archive prevents the write. S3 is the source of truth: edits
require connectivity and valid credentials, with no offline queue. Reconfigure
the same URI after disk failure; restore older snapshots with status-dashboard's
`task-store restore` command. Bucket versioning is also recommended.

`gws` is used **only for Calendar**. Re-authorisation requests exactly Calendar
read access (plus basic Google sign-in identity), and clears stale access tokens
only after a successful login:

```bash
gws auth login --scopes https://www.googleapis.com/auth/calendar.readonly
```

## Development

The UI and coach live in `ExperienceSampling/ExperienceSampling.swift`;
`ExperienceSampling/TaskStorage.swift` contains the S3 document and CLI transport.
See [CLAUDE.md](CLAUDE.md) for architecture notes and gotchas.

```bash
./rebuild-and-restart.sh   # typecheck, lint, rebuild, codesign, install, restart
./run-tests.sh             # headless logic tests
swiftlint lint --strict    # lint (config in .swiftlint.yml)
```

## CI

[GitHub Actions](.github/workflows/ci.yml) runs on every push to `main` and on
PRs, on a `macos-26` runner (matching the macOS version the app ships on):

- **test** — typechecks the app and runs the headless logic tests.
- **lint** — runs SwiftLint in `--strict` mode.
