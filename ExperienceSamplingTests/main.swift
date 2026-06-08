// Headless logic tests for ExperienceSampling.
//
// Compiled together with ExperienceSampling.swift under -DTESTING (which strips
// the app's NSApplication entry point) into a plain executable — see
// run-tests.sh. XCTest isn't available with only the Command Line Tools, so this
// uses a tiny assert harness that prints results and exits non-zero on failure.
//
// run-tests.sh runs this with HOME pointed at a throwaway temp dir, so the data
// stores (which resolve under ~/Library/Application Support) never touch real
// data. As a safety net we refuse to run unless HOME looks like a temp dir.

import Foundation

// MARK: - Harness

var failures = 0
var passes = 0

func check(_ cond: Bool, _ msg: String) {
    if cond { passes += 1; print("  ok   - \(msg)") }
    else { failures += 1; print("  FAIL - \(msg)") }
}

func checkEqual<T: Equatable>(_ got: T, _ want: T, _ msg: String) {
    check(got == want, "\(msg) (got \(got), want \(want))")
}

func section(_ name: String) { print("\n# \(name)") }

// MARK: - UserDefaults helpers (exact keys from PomodoroScheduler)

let kPhase = "pomodoroPhase"
let kStart = "pomodoroPhaseStart"
let kDuration = "pommadoroPhaseDuration"  // sic: matches the (typo'd) constant in source
let kTask = "pomodoroTask"
let allPomodoroKeys = [
    kPhase, kStart, kDuration, kTask, "pomodoroCount",
    "pomodoroWorkDuration", "pomodoroShortBreak", "pomodoroLongBreak",
    "pomodoroSnooze", "pomodoroBreakSnooze",
]

func clearSaved() {
    allPomodoroKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
}

func setSavedState(phase: String, startOffset: TimeInterval, duration: Int, task: String) {
    let d = UserDefaults.standard
    d.set(phase, forKey: kPhase)
    d.set(Date().addingTimeInterval(startOffset), forKey: kStart)
    d.set(duration, forKey: kDuration)
    d.set(task, forKey: kTask)
}

// MARK: - Isolation safety net

let home = NSHomeDirectory()
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
print("HOME       = \(home)")
print("appSupport = \(appSupport)")
let isolated = home.hasPrefix("/var/folders") || home.contains("/tmp") || home.contains("estest")
if !isolated {
    print("\nREFUSING TO RUN: HOME is not a throwaway temp dir, real data could be polluted.")
    print("Run via run-tests.sh, which sets HOME to a temp dir.")
    exit(2)
}

// MARK: - Tests

section("restoreState: wall-clock remaining (commit 21cbb5f)")
do {
    clearSaved()
    setSavedState(phase: "work", startOffset: -100, duration: 300, task: "refactor")
    let s = PomodoroScheduler()
    s.restoreState()
    checkEqual(s.phase, .work, "restores work phase")
    check(abs(s.timeRemaining - 200) <= 2, "timeRemaining ≈ duration - elapsed (got \(s.timeRemaining), want ~200)")
    checkEqual(s.currentTask, "refactor", "restores task")
}

section("restoreState: expired work session ends instead of restoring")
do {
    clearSaved()
    setSavedState(phase: "work", startOffset: -400, duration: 300, task: "x")
    let s = PomodoroScheduler()
    var ended = false
    s.onWorkSessionEnd = { ended = true }
    s.restoreState()
    check(ended, "onWorkSessionEnd called when elapsed > duration")
    check(UserDefaults.standard.string(forKey: kPhase) == nil, "saved phase cleared")
    checkEqual(s.phase, .idle, "phase left idle (not restored)")
}

section("restoreState: expired break ends")
do {
    clearSaved()
    setSavedState(phase: "shortBreak", startOffset: -400, duration: 300, task: "")
    let s = PomodoroScheduler()
    var ended = false
    s.onBreakEnd = { ended = true }
    s.restoreState()
    check(ended, "onBreakEnd called when break elapsed > duration")
}

section("restoreState: no saved state stays idle")
do {
    clearSaved()
    let s = PomodoroScheduler()
    s.restoreState()
    checkEqual(s.phase, .idle, "phase idle with nothing saved")
}

section("break snooze pending state (cancel/schedule)")
do {
    clearSaved()
    let s = PomodoroScheduler()
    check(!s.isBreakSnoozePending, "no break snooze pending initially")
    s.scheduleBreakSnooze()
    check(s.isBreakSnoozePending, "pending after scheduleBreakSnooze")
    s.cancelBreakSnooze()
    check(!s.isBreakSnoozePending, "not pending after cancelBreakSnooze")
}

section("startWork sets wall-clock fields (defaults)")
do {
    clearSaved()
    let s = PomodoroScheduler()
    s.startWork(task: "build")
    checkEqual(s.phase, .work, "phase is work")
    checkEqual(s.timeRemaining, 25 * 60, "timeRemaining = workDuration(25) * 60")
    checkEqual(s.currentTask, "build", "currentTask set")
}

section("startBreak sets duration by length")
do {
    clearSaved()
    let short = PomodoroScheduler()
    short.startBreak(isLong: false)
    checkEqual(short.phase, .shortBreak, "short break phase")
    checkEqual(short.timeRemaining, 5 * 60, "short break = shortBreakDuration(5) * 60")

    clearSaved()
    let long = PomodoroScheduler()
    long.startBreak(isLong: true)
    checkEqual(long.phase, .longBreak, "long break phase")
    checkEqual(long.timeRemaining, 15 * 60, "long break = longBreakDuration(15) * 60")
}

// MARK: - Summary

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
