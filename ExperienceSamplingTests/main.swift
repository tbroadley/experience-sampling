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
let kDuration = "pomodoroPhaseDuration"
let kLegacyDuration = "pommadoroPhaseDuration"  // old misspelling, migrated away
let kTask = "pomodoroTask"
let allPomodoroKeys = [
    kPhase, kStart, kDuration, kLegacyDuration, kTask, "pomodoroCount",
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

// These run first: the data stores are singletons that load() on first access,
// so the files must be seeded before anything else touches `.shared`. Guards the
// documented gotcha — encoder/decoder date strategies must both be .iso8601, and
// `try?` would silently swallow a mismatch into data loss.
let esDir = (appSupport as NSString).appendingPathComponent("ExperienceSampling")
try? FileManager.default.createDirectory(atPath: esDir, withIntermediateDirectories: true)
let isoFmt = ISO8601DateFormatter()
let seededDate = Date(timeIntervalSince1970: 1_700_000_000)  // whole seconds: round-trips exactly

func seedFile(_ name: String, _ data: Data) {
    try? data.write(to: URL(fileURLWithPath: (esDir as NSString).appendingPathComponent(name)))
}
func rawFile(_ name: String) -> String {
    (try? String(contentsOf: URL(fileURLWithPath: (esDir as NSString).appendingPathComponent(name)), encoding: .utf8)) ?? ""
}

section("DataStore: ISO8601 dates round-trip through load/save (regression)")
do {
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let seed = [Response(timestamp: seededDate, type: .startOfDay, excitement: 4)]
    if let d = try? enc.encode(seed) { seedFile("responses.json", d) }

    let loaded = DataStore.shared.fetchRecent()  // first access -> load()
    checkEqual(loaded.count, 1, "load() decoded the seeded response")
    check(loaded.first.map { Int($0.timestamp.timeIntervalSince1970) } == 1_700_000_000,
          "decoded timestamp matches (decoder is .iso8601)")

    DataStore.shared.add(Response(timestamp: Date(), type: .intraday, excitement: 3, activity: "x"))
    check(rawFile("responses.json").contains(isoFmt.string(from: seededDate)),
          "save() wrote an ISO8601 date string, not a number (encoder is .iso8601)")
}

section("PomodoroDataStore: ISO8601 dates round-trip through load/save (regression)")
do {
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let seed = [PomodoroSession(startTime: seededDate, taskDescription: "seed", completed: true, pomodoroNumber: 1)]
    if let d = try? enc.encode(seed) { seedFile("pomodoro-sessions.json", d) }

    let loaded = PomodoroDataStore.shared.fetchRecent()  // first access -> load()
    checkEqual(loaded.count, 1, "load() decoded the seeded session")
    check(loaded.first.map { Int($0.startTime.timeIntervalSince1970) } == 1_700_000_000,
          "decoded startTime matches (decoder is .iso8601)")

    PomodoroDataStore.shared.add(PomodoroSession(startTime: Date(), taskDescription: "x", completed: false, pomodoroNumber: 2))
    check(rawFile("pomodoro-sessions.json").contains(isoFmt.string(from: seededDate)),
          "save() wrote an ISO8601 date string, not a number (encoder is .iso8601)")
}

section("restoreState: wall-clock remaining (commit 21cbb5f)")
do {
    clearSaved()
    setSavedState(phase: "work", startOffset: -100, duration: 300, task: "refactor")
    let s = PomodoroScheduler()
    s.restoreState()
    checkEqual(s.phase, .work, "restores work phase")
    check(abs(s.timeRemaining - 200) <= 2, "timeRemaining ≈ duration - elapsed (got \(s.timeRemaining), want ~200)")
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

section("legacy phase-duration key is migrated")
do {
    clearSaved()
    let d = UserDefaults.standard
    d.set("work", forKey: kPhase)
    d.set(Date().addingTimeInterval(-100), forKey: kStart)
    d.set(300, forKey: kLegacyDuration)  // only the old misspelled key is set
    d.set("legacy", forKey: kTask)
    let s = PomodoroScheduler()  // init() runs migrateLegacyKeys()
    check(d.object(forKey: kLegacyDuration) == nil, "legacy key removed after migration")
    checkEqual(d.integer(forKey: kDuration), 300, "duration moved to corrected key")
    s.restoreState()
    checkEqual(s.phase, .work, "in-progress session restored after migration")
    check(abs(s.timeRemaining - 200) <= 2, "timeRemaining from migrated duration (got \(s.timeRemaining))")
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
    s.startWork()
    checkEqual(s.phase, .work, "phase is work")
    checkEqual(s.timeRemaining, 25 * 60, "timeRemaining = workDuration(25) * 60")
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

section("onBreakStart fires when a break starts (drives caffeination)")
do {
    clearSaved()
    let s = PomodoroScheduler()
    var started = 0
    s.onBreakStart = { started += 1 }
    s.startBreak(isLong: false)
    checkEqual(started, 1, "onBreakStart called once by startBreak")
}

section("onBreakStart fires when restoreState restores an in-progress break")
do {
    clearSaved()
    setSavedState(phase: "shortBreak", startOffset: -100, duration: 300, task: "")
    let s = PomodoroScheduler()
    var started = false
    s.onBreakStart = { started = true }
    s.restoreState()
    check(started, "onBreakStart called for a restored break (survives app restart)")
}

section("onBreakStart does not fire when restoreState restores work")
do {
    clearSaved()
    setSavedState(phase: "work", startOffset: -100, duration: 300, task: "refactor")
    let s = PomodoroScheduler()
    var started = false
    s.onBreakStart = { started = true }
    s.restoreState()
    check(!started, "onBreakStart not called for a restored work session")
}

// MARK: - BreakCaffeinator

section("BreakCaffeinator.shouldCaffeinate truth table")
do {
    typealias C = BreakCaffeinator
    check(!C.shouldCaffeinate(mode: .off, locked: false, capReached: false), "off + present -> no")
    check(!C.shouldCaffeinate(mode: .off, locked: true, capReached: false), "off + away -> no")
    check(!C.shouldCaffeinate(mode: .work, locked: false, capReached: false), "work + present -> no (machine won't idle-sleep)")
    check(C.shouldCaffeinate(mode: .work, locked: true, capReached: false), "work + away -> yes")
    check(C.shouldCaffeinate(mode: .onBreak, locked: false, capReached: false), "break + present -> yes")
    check(C.shouldCaffeinate(mode: .onBreak, locked: true, capReached: false), "break + away -> yes")
    check(C.shouldCaffeinate(mode: .awaitingReturn, locked: true, capReached: false), "awaitingReturn + away -> yes")
    check(!C.shouldCaffeinate(mode: .awaitingReturn, locked: false, capReached: false), "awaitingReturn + present -> no")
    check(!C.shouldCaffeinate(mode: .work, locked: true, capReached: true), "cap reached overrides work + away")
    check(!C.shouldCaffeinate(mode: .onBreak, locked: true, capReached: true), "cap reached overrides break")
}

// Drives a caffeinator with a controllable lock state and records the latest
// desired caffeination so the side effect (spawning `caffeinate`) never runs.
func makeCaffeinator() -> (BreakCaffeinator, () -> Bool, (Bool) -> Void) {
    var locked = false
    var caffeinated = false
    let c = BreakCaffeinator(
        isScreenLocked: { locked },
        onSetCaffeinated: { caffeinated = $0 }
    )
    return (c, { caffeinated }, { locked = $0 })
}

section("BreakCaffeinator: work caffeinates only while the screen is locked")
do {
    let (c, caffeinated, setLocked) = makeCaffeinator()
    c.workStarted()
    check(!caffeinated(), "work while present -> not caffeinating")
    setLocked(true); c.screenDidLock()
    check(caffeinated(), "work after locking (stepped away) -> caffeinating")
    setLocked(false); c.screenDidUnlock()
    check(!caffeinated(), "work after returning -> stops")
}

section("BreakCaffeinator: break caffeinates regardless of lock state")
do {
    let (c, caffeinated, _) = makeCaffeinator()
    c.breakStarted()
    check(caffeinated(), "break while present -> caffeinating")
}

section("BreakCaffeinator: break ending while away stays awake until return")
do {
    let (c, caffeinated, setLocked) = makeCaffeinator()
    c.breakStarted()
    setLocked(true); c.screenDidLock()
    c.breakEnded()
    checkEqual(c.mode, BreakCaffeinator.Mode.awaitingReturn, "break ended while locked -> awaitingReturn")
    check(caffeinated(), "still caffeinating while user is away")
    setLocked(false); c.screenDidUnlock()
    checkEqual(c.mode, BreakCaffeinator.Mode.off, "returning -> off")
    check(!caffeinated(), "stops once the user returns")
}

section("BreakCaffeinator: break ending while present stops immediately")
do {
    let (c, caffeinated, _) = makeCaffeinator()
    c.breakStarted()
    c.breakEnded()
    checkEqual(c.mode, BreakCaffeinator.Mode.off, "break ended while present -> off")
    check(!caffeinated(), "not caffeinating")
}

section("BreakCaffeinator: 1-hour away cap stops caffeination (end-of-day on break)")
do {
    let (c, caffeinated, setLocked) = makeCaffeinator()
    c.breakStarted()
    setLocked(true); c.screenDidLock()
    c.breakEnded()
    check(caffeinated(), "still awake right after locking on break")
    c.handleAwayCapElapsed()
    check(c.awayCapReached, "away cap marked reached")
    check(!caffeinated(), "stops after 1 hour locked, so it won't run all night")
}

section("BreakCaffeinator: returning after the cap resets and re-arms")
do {
    let (c, caffeinated, setLocked) = makeCaffeinator()
    c.workStarted()
    setLocked(true); c.screenDidLock()
    c.handleAwayCapElapsed()
    check(!caffeinated(), "capped out during a locked work session")
    setLocked(false); c.screenDidUnlock()
    check(!c.awayCapReached, "unlocking clears the cap")
    setLocked(true); c.screenDidLock()
    check(caffeinated(), "stepping away again re-caffeinates")
}

section("BreakCaffeinator: sessionEnded stops caffeinating even while locked")
do {
    let (c, caffeinated, setLocked) = makeCaffeinator()
    c.workStarted()
    setLocked(true); c.screenDidLock()
    check(caffeinated(), "caffeinating during away work session")
    c.sessionEnded()
    checkEqual(c.mode, BreakCaffeinator.Mode.off, "abandon -> off")
    check(!caffeinated(), "abandoning stops caffeination")
}

// MARK: - Summary

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
