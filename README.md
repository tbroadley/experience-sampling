# Experience Sampling

[![CI](https://github.com/tbroadley/experience-sampling/actions/workflows/ci.yml/badge.svg)](https://github.com/tbroadley/experience-sampling/actions/workflows/ci.yml)

A macOS menu-bar app for experience sampling, pomodoro sessions, and a Todoist-driven focus coach.

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

## Development

The app is a single Swift file (`ExperienceSampling/ExperienceSampling.swift`).
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
