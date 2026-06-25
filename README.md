# Experience Sampling

[![CI](https://github.com/tbroadley/experience-sampling/actions/workflows/ci.yml/badge.svg)](https://github.com/tbroadley/experience-sampling/actions/workflows/ci.yml)

A macOS menu-bar app for experience sampling, pomodoro sessions, and a Todoist-driven focus coach.

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
