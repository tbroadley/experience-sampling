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
    checkEqual(s.phase, .work, "completed work awaits its break, just like live expiry")
    checkEqual(s.menuAction, .takeBreak, "restored completed work offers Take Break Now, not Start or Abandon")
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

section("endToIdle: returns to idle and clears saved state (no break follows)")
do {
    clearSaved()
    let s = PomodoroScheduler()
    s.startWork()
    checkEqual(s.phase, .work, "work started")
    check(UserDefaults.standard.string(forKey: kPhase) != nil, "state saved while working")
    s.endToIdle()
    checkEqual(s.phase, .idle, "phase is idle after endToIdle")
    check(UserDefaults.standard.string(forKey: kPhase) == nil, "saved state cleared after endToIdle")
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

// MARK: - Pomodoro menu states and transitions

section("Pomodoro menu: exactly one appropriate control in every state")
do {
    let cases: [(PomodoroPhase, Int, PomodoroMenuAction)] = [
        (.idle, 0, .start), (.idle, 300, .start),
        (.work, 3000, .abandon), (.work, 1, .abandon), (.work, 0, .takeBreak),
        (.shortBreak, 300, .endBreak), (.shortBreak, 0, .endBreak),
        (.longBreak, 900, .endBreak), (.longBreak, 0, .endBreak),
    ]
    for (phase, seconds, expected) in cases {
        checkEqual(PomodoroMenuAction.action(phase: phase, secondsRemaining: seconds), expected,
                   "\(phase) with \(seconds)s remaining offers \(expected.rawValue)")
    }
    clearSaved()
    let s = PomodoroScheduler()
    s.scheduleSnooze()
    checkEqual(s.menuAction, .start, "snoozing the next pomodoro still allows an explicit start")
    s.phase = .work
    s.timeRemaining = 0
    s.scheduleBreakSnooze()
    checkEqual(s.menuAction, .takeBreak, "snoozing a completed pomodoro's break only offers Take Break Now")
    s.startBreak(isLong: false)
    check(!s.isBreakSnoozePending, "starting the break cancels its snooze")
    checkEqual(s.menuAction, .endBreak, "the break replaces Take Break Now with End Break")
    s.endBreak()
    checkEqual(s.menuAction, .start, "ending the break restores Start Pomodoro")
}

section("End Break preserves completed work and uses the normal break-end callback")
for isLong in [false, true] {
    clearSaved()
    let store = PomodoroDataStore.shared
    let completed = PomodoroSession(startTime: Date(), endTime: Date(), taskDescription: "",
                                    completed: true, pomodoroNumber: 1, plannedMinutes: 50)
    store.add(completed)
    let before = store.completedTodayCount(workDuration: 50)
    let s = PomodoroScheduler()
    s.startBreak(isLong: isLong)
    s.startWork()
    checkEqual(s.phase, isLong ? .longBreak : .shortBreak, "a stale Start Pomodoro action cannot replace a break")
    var ended = 0
    var lastTick: PomodoroPhase?
    s.onTimerTick = { _, phase in lastTick = phase }
    s.onBreakEnd = {
        ended += 1
        checkEqual(s.phase, .idle, "the break-end callback sees idle")
    }
    s.endBreak()
    checkEqual(ended, 1, "ending a \(isLong ? "long" : "short") break fires the callback once")
    checkEqual(s.timeRemaining, 0, "ending the break clears remaining time")
    checkEqual(lastTick, .idle, "the menu-bar icon is refreshed to idle")
    check(UserDefaults.standard.object(forKey: kPhase) == nil, "the ended break cannot restore after restart")
    checkEqual(store.completedTodayCount(workDuration: 50), before, "ending a break never removes daily credit")
    checkEqual(store.fetchRecent(limit: 500).first { $0.id == completed.id }?.endTime, completed.endTime,
               "ending a break leaves the completed session's end time untouched")
    s.endBreak()
    checkEqual(ended, 1, "a repeated/stale End Break action is harmless")
}

section("Invalid or stale actions cannot restart work or undo a completed session")
do {
    clearSaved()
    let s = PomodoroScheduler()
    s.startWork()
    let count = s.pomodoroCount
    s.startWork()
    checkEqual(s.pomodoroCount, count, "Start Pomodoro during work cannot start a duplicate session")
    s.endBreak()
    checkEqual(s.phase, .work, "End Break during work does nothing")
    s.abandon()
    checkEqual(s.phase, .idle, "abandoning active work returns to idle")
    checkEqual(PomodoroDataStore.shared.fetchRecent().first?.completed, false, "abandoned work stays incomplete")

    let store = PomodoroDataStore.shared
    let completed = PomodoroSession(startTime: Date(), endTime: Date(), taskDescription: "",
                                    completed: true, pomodoroNumber: 1, plannedMinutes: 50)
    store.add(completed)
    for phase: PomodoroPhase in [.idle, .work, .shortBreak, .longBreak] {
        s.phase = phase
        s.timeRemaining = 0
        s.abandon()
        checkEqual(store.fetchRecent(limit: 500).first { $0.id == completed.id }?.completed, true,
                   "abandon from \(phase) without active work cannot undo completion")
    }
}

section("Natural work expiry offers a break and keeps completed credit")
do {
    clearSaved()
    let store = PomodoroDataStore.shared
    let completed = PomodoroSession(startTime: Date(), taskDescription: "", completed: false,
                                    pomodoroNumber: 1, plannedMinutes: 45)
    store.add(completed)
    let before = store.completedTodayCount(workDuration: 50)
    setSavedState(phase: "work", startOffset: 0, duration: 1, task: "")
    let s = PomodoroScheduler()
    var ended = 0
    s.onWorkSessionEnd = { ended += 1 }
    s.restoreState()
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    checkEqual(ended, 1, "natural work expiry fires once")
    checkEqual(s.menuAction, .takeBreak, "completed work immediately offers Take Break Now")
    checkEqual(store.completedTodayCount(workDuration: 50), before + 1, "the 90%-length session now counts")
    s.abandon()
    checkEqual(store.completedTodayCount(workDuration: 50), before + 1, "a stale Abandon action cannot undo that credit")
}

section("Natural break expiry refreshes the menu to idle")
do {
    clearSaved()
    setSavedState(phase: "shortBreak", startOffset: 0, duration: 1, task: "")
    let s = PomodoroScheduler()
    var lastTick: PomodoroPhase?
    var ended = 0
    s.onTimerTick = { _, phase in lastTick = phase }
    s.onBreakEnd = { ended += 1 }
    s.restoreState()
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    checkEqual(s.phase, .idle, "the break expired")
    checkEqual(lastTick, .idle, "the last tick is idle, not a break stuck at 00:00")
    checkEqual(ended, 1, "natural expiry fires the same callback as End Break")
    checkEqual(s.menuAction, .start, "natural expiry offers Start Pomodoro")
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

// MARK: - MeetingAttentionMonitor

section("MeetingAttentionMonitor.classify")
do {
    typealias M = MeetingAttentionMonitor
    let allow = ["Notion", "Todoist", "zoom.us"]
    checkEqual(M.classify(appName: "Google Chrome", windowTitle: "Meet — Standup", allowlist: allow),
               M.Decision.onMeeting, "browser on a Meet tab -> onMeeting")
    checkEqual(M.classify(appName: "Google Chrome", windowTitle: "Hacker News", allowlist: allow),
               M.Decision.distraction, "browser on a non-meeting tab -> distraction")
    checkEqual(M.classify(appName: "Safari", windowTitle: nil, allowlist: allow),
               M.Decision.onMeeting, "browser with unreadable title -> onMeeting (don't nag without AX)")
    checkEqual(M.classify(appName: "Notion", windowTitle: "Meeting notes", allowlist: allow),
               M.Decision.allowed, "allowlisted app -> allowed")
    checkEqual(M.classify(appName: "zoom.us", windowTitle: "Zoom Meeting", allowlist: allow),
               M.Decision.allowed, "native Zoom app (allowlisted) -> allowed")
    checkEqual(M.classify(appName: "Slack", windowTitle: "general", allowlist: allow),
               M.Decision.distraction, "non-allowlisted, non-browser app -> distraction")
}

section("MeetingAttentionMonitor: linger accrues to the threshold, then nudges")
do {
    let m = MeetingAttentionMonitor()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    check(!m.step(now: t0, meetingActive: true, appName: "Slack", windowTitle: nil),
          "first distraction step arms the linger clock, no nudge yet")
    check(!m.step(now: t0.addingTimeInterval(10), meetingActive: true, appName: "Slack", windowTitle: nil),
          "still under the 25s threshold")
    check(m.step(now: t0.addingTimeInterval(30), meetingActive: true, appName: "Slack", windowTitle: nil),
          "past the threshold -> nudge")
    check(!m.step(now: t0.addingTimeInterval(35), meetingActive: true, appName: "Slack", windowTitle: nil),
          "while the nudge is showing, no repeat nudge")
}

section("MeetingAttentionMonitor: returning to the meeting resets the linger clock")
do {
    let m = MeetingAttentionMonitor()
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    _ = m.step(now: t0, meetingActive: true, appName: "Slack", windowTitle: nil)
    check(!m.step(now: t0.addingTimeInterval(5), meetingActive: true, appName: "Google Chrome", windowTitle: "Meet — x"),
          "back on the Meet tab clears the clock")
    check(!m.step(now: t0.addingTimeInterval(40), meetingActive: true, appName: "Slack", windowTitle: nil),
          "drifting again restarts the clock from scratch (no immediate nudge)")
}

section("MeetingAttentionMonitor: no meeting (mic/camera off) never nudges")
do {
    let m = MeetingAttentionMonitor()
    let t0 = Date(timeIntervalSince1970: 5_000_000)
    _ = m.step(now: t0, meetingActive: false, appName: "Slack", windowTitle: nil)
    check(!m.step(now: t0.addingTimeInterval(60), meetingActive: false, appName: "Slack", windowTitle: nil),
          "not in a meeting -> no nudge no matter how long")
}

section("MeetingAttentionMonitor: dismiss re-arms; snooze mutes until the meeting ends")
do {
    let m = MeetingAttentionMonitor()
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    _ = m.step(now: t0, meetingActive: true, appName: "Slack", windowTitle: nil)
    check(m.step(now: t0.addingTimeInterval(30), meetingActive: true, appName: "Slack", windowTitle: nil),
          "nudge fires")
    m.snoozeForMeeting()
    check(!m.step(now: t0.addingTimeInterval(120), meetingActive: true, appName: "Slack", windowTitle: nil),
          "snoozed -> no nudge for the rest of the meeting")
    for i in 0..<3 {
        _ = m.step(now: t0.addingTimeInterval(130 + Double(i)), meetingActive: false, appName: "Slack", windowTitle: nil)
    }
    _ = m.step(now: t0.addingTimeInterval(200), meetingActive: true, appName: "Slack", windowTitle: nil)
    check(m.step(now: t0.addingTimeInterval(230), meetingActive: true, appName: "Slack", windowTitle: nil),
          "once the meeting ends (sustained AV-off) the snooze lifts and nudges resume")
}

// MARK: - Middleman / Hawk auth

section("MiddlemanClient: endpoint and auth shape")
do {
    // The real host is configuration, not source (this repo is public), so assert
    // the path the base URL gets composed into rather than the host itself.
    let previous = UserDefaults.standard.string(forKey: "middlemanBaseURL")
    UserDefaults.standard.set("https://proxy.example", forKey: "middlemanBaseURL")
    checkEqual(MiddlemanClient.messagesURL?.absoluteString,
               "https://proxy.example/anthropic/v1/messages",
               "Anthropic passthrough endpoint composed from the configured base URL")
    if let previous {
        UserDefaults.standard.set(previous, forKey: "middlemanBaseURL")
    } else {
        UserDefaults.standard.removeObject(forKey: "middlemanBaseURL")
    }
    checkEqual(MiddlemanClient.anthropicVersion, "2023-06-01", "anthropic-version header value")
}

section("MiddlemanClient.hawkEnvValue: parses hawk's env file")
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("es-hawk-env-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("env")
    let sample = """
    # CLI
    HAWK_API_URL=https://api.example

    HAWK_MIDDLEMAN_URL="https://proxy.example"
    HAWK_OTHER=ignored
    """
    try? sample.write(to: file, atomically: true, encoding: .utf8)

    checkEqual(MiddlemanClient.hawkEnvValue(for: "HAWK_MIDDLEMAN_URL", envPath: file),
               "https://proxy.example", "reads the value and strips surrounding quotes")
    checkEqual(MiddlemanClient.hawkEnvValue(for: "HAWK_API_URL", envPath: file),
               "https://api.example", "reads an unquoted value")
    check(MiddlemanClient.hawkEnvValue(for: "HAWK_ABSENT", envPath: file) == nil,
          "absent key returns nil")
    check(MiddlemanClient.hawkEnvValue(for: "HAWK_MIDDLEMAN_URL",
                                       envPath: dir.appendingPathComponent("missing")) == nil,
          "missing file returns nil rather than throwing")
    try? FileManager.default.removeItem(at: dir)
}

section("MiddlemanClient.classify: HTTP failures map to actionable cases")
do {
    func body(_ type: String, _ message: String) -> Data {
        // swiftlint:disable:next force_try - fixed literal, can't fail.
        try! JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": type, "message": message]])
    }

    let unauthorized = MiddlemanClient.classify(status: 401, body: body("authentication_error", "invalid api key"), model: "claude-sonnet-5")
    checkEqual(unauthorized.kind, "token-rejected", "401 -> token rejected")
    check(unauthorized.isAuthProblem, "401 is an auth problem")
    check(!unauthorized.isTransient, "401 is not retried as transient")

    let forbidden = MiddlemanClient.classify(status: 403, body: Data(), model: "claude-sonnet-5")
    checkEqual(forbidden.kind, "token-rejected", "403 -> token rejected")

    // hawk models lists snapshots the upstream key can't call; those 404 by name.
    let missingModel = MiddlemanClient.classify(status: 404, body: body("not_found_error", "model: claude-3-opus-20240229"),
                                                model: "claude-3-opus-20240229")
    checkEqual(missingModel.kind, "model-not-entitled", "404 naming the model -> not entitled")
    check(!missingModel.isAuthProblem, "a missing model is not an auth problem")
    check(!missingModel.isTransient, "a missing model is not worth retrying")

    let rateLimited = MiddlemanClient.classify(status: 429, body: body("rate_limit_error", "slow down"), model: "claude-sonnet-5")
    checkEqual(rateLimited.kind, "http-429", "429 -> plain HTTP error")
    check(rateLimited.isTransient, "429 is transient")

    let serverError = MiddlemanClient.classify(status: 503, body: Data(), model: "claude-sonnet-5")
    check(serverError.isTransient, "5xx is transient")

    let badRequest = MiddlemanClient.classify(status: 400, body: body("invalid_request_error", "bad max_tokens"), model: "claude-sonnet-5")
    check(!badRequest.isTransient, "400 is not transient")
    check(badRequest.detail.contains("bad max_tokens"), "the upstream message survives into the log detail")
}

section("MiddlemanClient: network errors are told apart from server errors")
do {
    check(MiddlemanClient.isNetworkFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)),
          "offline counts as a network failure")
    check(MiddlemanClient.isNetworkFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
          "timeout counts as a network failure")
    check(!MiddlemanClient.isNetworkFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)),
          "a bad server response is not a network failure")
    check(!MiddlemanClient.isNetworkFailure(NSError(domain: NSCocoaErrorDomain, code: 4)),
          "non-URL errors are not network failures")
}

section("MiddlemanClient: backoff grows and is bounded")
do {
    checkEqual(MiddlemanClient.backoffDelay(afterAttempt: 1), 2.0, "first retry waits 2s")
    checkEqual(MiddlemanClient.backoffDelay(afterAttempt: 2), 6.0, "second retry waits 6s")
    checkEqual(MiddlemanClient.maxAttempts, 3, "three tries total")
}

section("HawkAuth: JWT expiry parsing (no signature validation)")
do {
    func jwt(exp: Double?) -> String {
        var payload: [String: Any] = ["sub": "someone"]
        if let exp { payload["exp"] = exp }
        // swiftlint:disable:next force_try - fixed literal, can't fail.
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let segment = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(segment).signature"
    }

    checkEqual(HawkAuth.expiry(fromJWT: jwt(exp: 1_700_000_000)),
               Date(timeIntervalSince1970: 1_700_000_000),
               "reads exp out of the payload")
    check(HawkAuth.expiry(fromJWT: jwt(exp: nil)) == nil, "no exp claim -> nil")
    check(HawkAuth.expiry(fromJWT: "not-a-jwt") == nil, "garbage -> nil")
    check(HawkAuth.expiry(fromJWT: "header.!!!not-base64!!!.sig") == nil, "undecodable payload -> nil")
}

section("HawkAuth: hawk is looked up by absolute path (a GUI app has no useful PATH)")
do {
    check(HawkAuth.searchPaths.allSatisfy { $0.hasPrefix("/") }, "every candidate is absolute")
    check(HawkAuth.searchPaths.contains { $0.hasSuffix("/.local/bin/hawk") }, "the uv tool install location is covered")

    UserDefaults.standard.set("/definitely/not/here/hawk", forKey: "hawkPath")
    check(HawkAuth.executablePath() == nil, "a bogus hawkPath override resolves to nothing rather than falling back")
    UserDefaults.standard.removeObject(forKey: "hawkPath")
}

section("HawkAuth: a missing hawk fails loudly instead of silently")
do {
    UserDefaults.standard.set("/definitely/not/here/hawk", forKey: "hawkPath")
    HawkAuth.invalidateCachedToken()
    let result = HawkAuth.token()
    switch result {
    case .success:
        check(false, "no hawk should never yield a token")
    case .failure(let error):
        checkEqual(error.kind, "hawk-missing", "no hawk -> hawkMissing")
        check(error.isAuthProblem, "hawkMissing is an auth problem")
        check(!error.advice.isEmpty, "the error carries advice for the user")
    }
    UserDefaults.standard.removeObject(forKey: "hawkPath")
    HawkAuth.invalidateCachedToken()
}

section("CoachErrorThrottle: first failure is loud, repeats are quiet, success re-arms")
do {
    var throttle = CoachErrorThrottle()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let authError = CoachError.notAuthenticated("expired")
    let netError = CoachError.networkUnavailable("offline")

    check(!throttle.hasRecordedFailures, "starts clean")
    check(throttle.shouldSurface(authError, now: t0), "first auth failure surfaces")
    check(!throttle.shouldSurface(authError, now: t0.addingTimeInterval(60)), "a repeat a minute later stays quiet")
    check(throttle.shouldSurface(netError, now: t0.addingTimeInterval(60)), "a different kind still surfaces")
    check(throttle.shouldSurface(authError, now: t0.addingTimeInterval(CoachErrorThrottle.interval + 1)),
          "the same kind surfaces again once the interval has passed")
    check(throttle.hasRecordedFailures, "failures are remembered")

    throttle.reset()
    check(!throttle.hasRecordedFailures, "a success clears the memory")
    check(throttle.shouldSurface(authError, now: t0.addingTimeInterval(61)), "and the next failure is loud again")
}

section("CoachError: every case is user-presentable")
do {
    let all: [CoachError] = [
        .hawkMissing("x"), .notAuthenticated("x"), .tokenRejected("x"), .networkUnavailable("x"),
        .modelNotEntitled("claude-sonnet-5"), .httpError(status: 500, detail: "x"), .badResponse("x"),
        .proxyNotConfigured("x"), .tasksNotConfigured("x"), .tasksAuthRequired("x"), .tasksUnavailable("x")
    ]
    check(all.allSatisfy { !$0.title.isEmpty }, "all cases have a title")
    check(all.allSatisfy { !$0.advice.isEmpty }, "all cases have advice")
    check(Set(all.map(\.kind)).count == all.count, "kinds are distinct, so the throttle can't conflate them")
    check(!all.contains { $0.isAuthProblem && $0.isTransient }, "no case is both an auth problem and retried as transient")
}

section("TasksClient: the shared task schema matches status-dashboard")
do {
    // A: id | B: content | C: project | D: description | E: due
    // F: recurrence | G: order | H: done | I: completed_at
    func row(_ cells: String...) -> [String] {
        cells + Array(repeating: "", count: max(0, 9 - cells.count))
    }
    let today = "2026-08-10"
    let rows = [
        row("a", "Overdue thing", "", "", "2026-08-07", "", "5", "FALSE"),
        row("b", "Top thing", "", "", today, "", "-2", "FALSE"),
        row("c", "Already done", "", "", today, "", "-9", "TRUE", "2026-08-10T09:15:00-04:00"),
        row("d", "Tomorrow's thing", "", "", "2026-08-11", "", "-7", "FALSE"),
        row("e", "No due date", "", "", "", "", "-8", "FALSE"),
        row("f", "Done yesterday", "", "", "2026-08-09", "", "3", "TRUE", "2026-08-09T17:00:00-04:00")
    ]

    checkEqual(TasksClient.topTodo(rows: rows, today: today)?.content, "Top thing",
               "lowest order among today's incomplete tasks wins")
    checkEqual(TasksClient.topTodo(rows: rows, today: "2026-08-07")?.content, "Overdue thing",
               "a future task never becomes the top to-do")
    check(TasksClient.topTodo(rows: [row("x", "Done", "", "", today, "", "0", "TRUE")], today: today) == nil,
          "a fully-completed list has no top to-do")

    let completed = TasksClient.completedToday(rows: rows, today: today)
    checkEqual(completed.count, 1, "only today's completions count")
    checkEqual(completed.first?.content, "Already done", "and they carry their content")

    checkEqual(TasksClient.newTaskRow(content: "Ship it", id: "id-1", today: today),
               ["id-1", "Ship it", "", "", today, "", "0", "FALSE", ""],
               "a new row matches status-dashboard's column layout")

    check(TasksClient.isTrue("TRUE") && TasksClient.isTrue(" true "), "done is case- and space-insensitive")
    check(!TasksClient.isTrue("") && !TasksClient.isTrue("FALSE"), "anything else is not done")

    let env = """
    # location is local configuration, never bundled
    export TASKS_S3_URI="s3://example-bucket/tasks.json"
    """
    checkEqual(TaskConfiguration.parseEnvValue(env, key: "TASKS_S3_URI"), "s3://example-bucket/tasks.json",
               "the task URI is inherited from status-dashboard's env file")
    check(TaskConfiguration.parseEnvValue(env, key: "MISSING") == nil, "an absent key reads as nil")

    check(CalendarCLI.looksLikeAuthFailure("Error: invalid_grant"), "an auth-shaped gws failure is recognised")
    check(!CalendarCLI.looksLikeAuthFailure("Error: ENOTFOUND"), "a network failure is not an auth problem")
    check(CalendarCLI.looksLikeAuthFailure("{code: 403, reason: insufficientPermissions}"),
          "a missing OAuth scope reads as an auth problem, not a transient one")
    checkEqual(CalendarCLI.requiredScope, "https://www.googleapis.com/auth/calendar.readonly", "Google is Calendar-read-only")
    check(CoachError.tasksAuthRequired("x").fixAction != .gwsSignIn, "AWS task errors never reauthorize Google")

    checkEqual(CalendarCLI.nodeVersionOrder("v24.12.0"), [24, 12, 0], "an nvm directory parses to its components")
    check(CalendarCLI.nodeVersionOrder("v9.0.0")
            .lexicographicallyPrecedes(CalendarCLI.nodeVersionOrder("v24.12.0")),
          "v24 outranks v9")
    checkEqual(CalendarCLI.nodeVersionOrder("not-a-version"), [], "a junk directory name sorts last")

    check(CoachError.tasksNotConfigured("x").isAuthProblem, "a missing sheet is not retried in a loop")
    check(CoachError.tasksUnavailable("x").isTransient, "an unreadable sheet is retried")
    checkEqual(CoachError.tasksNotConfigured("x").fixAction, CoachError.FixAction.tasksSettings,
               "the modal points at Settings, not a Hawk sign-in")
    checkEqual(CoachError.notAuthenticated("x").fixAction, CoachError.FixAction.hawkSignIn,
               "Hawk errors still offer a Hawk sign-in")
}

section("CalendarMonitor: read failures are surfaced, not just logged")
do {
    // The exact string that took meeting support out for twelve days, as gws
    // actually emits it (403 in the body, zero exit code).
    let scopeDetail = "gws API error: {code: 403, message: Request had insufficient authentication scopes., reason: insufficientPermissions}"
    check(CalendarMonitor.looksLikeMissingScope(scopeDetail), "the real-world scope failure is recognised")
    check(CalendarMonitor.looksLikeMissingScope("error[api]: Request had insufficient authentication scopes."),
          "gws's own wording is recognised too")
    check(!CalendarMonitor.looksLikeMissingScope("gws calendar exited 5: HTTP request failed"),
          "an ordinary failure is not mistaken for a scope problem")

    // runGws classifies a 403 as calendarAuthRequired (looksLikeAuthFailure matches
    // "403"), so the scope case has to be picked out of the detail, not the case.
    checkEqual(CalendarMonitor.calendarError(from: .calendarAuthRequired(scopeDetail)).kind,
               "calendar-scope-missing",
               "a scope failure is re-labelled even though runGws called it an auth failure")
    checkEqual(CalendarMonitor.calendarError(from: .calendarAuthRequired("invalid_grant")).kind,
               "calendar-auth-required",
               "a genuine sign-in failure stays an auth failure")
    checkEqual(CalendarMonitor.calendarError(from: .calendarUnavailable("gws not found")).kind,
               "calendar-unavailable",
               "everything else is a plain calendar outage")

    // The whole point of the change: these reach the user, and point at the
    // re-grant rather than the spreadsheet settings.
    checkEqual(CoachError.calendarScopeMissing("x").fixAction, CoachError.FixAction.gwsSignIn,
               "a missing scope offers the Google re-authorise button")
    checkEqual(CoachError.calendarAuthRequired("x").fixAction, CoachError.FixAction.gwsSignIn,
               "so does a missing Google sign-in")
    check(CoachError.calendarScopeMissing("x").isAuthProblem, "a missing scope is not retried in a loop")
    check(CoachError.calendarUnavailable("x").isTransient, "a transient calendar outage is retried")
    check(!CoachError.calendarScopeMissing("x").isTransient,
          "a missing scope is never retried — only a re-grant fixes it")

    check(CoachError.calendarScopeMissing("x").title.hasPrefix("Calendar:"),
          "the modal says Calendar, not Focus coach — the coach itself is fine")
    check(CoachError.calendarScopeMissing("x").advice.contains("calendar"),
          "the advice names the scope that has to be granted")

    // The pinned menu-bar row is keyed off this prefix, so both recovery
    // handlers can tell whose error is showing.
    check(CoachError.calendarUnavailable("x").kind.hasPrefix("calendar-"),
          "calendar kinds share the prefix the menu-bar row keys off")
    check(!CoachError.tasksUnavailable("x").kind.hasPrefix("calendar-"),
          "a tasks error is not mistaken for a calendar one")

    // Throttling: one modal per kind per window, not one every 5-minute refresh.
    var throttle = CoachErrorThrottle()
    let start = Date()
    check(throttle.shouldSurface(.calendarScopeMissing("x"), now: start), "the first failure surfaces")
    check(!throttle.shouldSurface(.calendarScopeMissing("x"), now: start.addingTimeInterval(60)),
          "the same failure a minute later is swallowed")
    check(throttle.shouldSurface(.calendarScopeMissing("x"), now: start.addingTimeInterval(11 * 60)),
          "it surfaces again once the window has passed")
    throttle.reset()
    check(throttle.shouldSurface(.calendarScopeMissing("x"), now: start.addingTimeInterval(11 * 60)),
          "a recovery re-arms the throttle, so the next break is loud again")
}

section("PromptPolicy: weekends are quiet unless there's work happening")
do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    func day(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = cal.timeZone
        return f.date(from: iso)!
    }
    let saturday = day("2026-08-08T11:00:00-04:00")
    let monday = day("2026-08-10T11:00:00-04:00")

    check(cal.isDateInWeekend(saturday), "sanity: the fixture Saturday is a weekend")
    check(!cal.isDateInWeekend(monday), "sanity: the fixture Monday is not")

    check(PromptPolicy.allowStartOfDayPrompt(now: monday, quietWeekends: true, calendar: cal),
          "weekday start-of-day prompt still fires")
    check(!PromptPolicy.allowStartOfDayPrompt(now: saturday, quietWeekends: true, calendar: cal),
          "weekend start-of-day prompt is suppressed")
    check(PromptPolicy.allowStartOfDayPrompt(now: saturday, quietWeekends: false, calendar: cal),
          "turning quiet weekends off restores it")

    check(PromptPolicy.allowIntradayPrompt(now: monday, inPomodoro: false, userPresent: false,
                                           quietWeekends: true, calendar: cal),
          "weekday check-ins fire regardless of presence")
    check(!PromptPolicy.allowIntradayPrompt(now: saturday, inPomodoro: false, userPresent: false,
                                            quietWeekends: true, calendar: cal),
          "weekend check-in is dropped when away and not in a pomodoro")
    check(PromptPolicy.allowIntradayPrompt(now: saturday, inPomodoro: true, userPresent: false,
                                           quietWeekends: true, calendar: cal),
          "a weekend pomodoro re-enables check-ins")
    check(PromptPolicy.allowIntradayPrompt(now: saturday, inPomodoro: false, userPresent: true,
                                           quietWeekends: true, calendar: cal),
          "being at the Mac on a weekend re-enables check-ins")

    check(!PromptPolicy.userIsPresent(idleSeconds: 0, screenLocked: true), "a locked screen means away")
    check(!PromptPolicy.userIsPresent(idleSeconds: PromptPolicy.activityWindow + 1, screenLocked: false),
          "no input for longer than the window means away")
    check(PromptPolicy.userIsPresent(idleSeconds: 5, screenLocked: false), "recent input means present")
}

// MARK: - Daily pomodoro count

section("PomodoroSession: at least 90% of configured duration counts")
do {
    let cases: [(Int?, Int, Bool)] = [
        (44, 50, false), (45, 50, true), (46, 50, true), (47, 50, true),
        (48, 50, true), (49, 50, true), (50, 50, true), (55, 50, true),
        (22, 25, false), (23, 25, true), (25, 25, true),
        (53, 60, false), (54, 60, true), (9, 10, true),
        (0, 50, false), (nil, 50, true),
    ]
    for (planned, configured, expected) in cases {
        let session = PomodoroSession(startTime: Date(), taskDescription: "", completed: true,
                                      pomodoroNumber: 1, plannedMinutes: planned)
        checkEqual(session.meetsDailyCountThreshold(workDuration: configured), expected,
                   "\(planned.map(String.init) ?? "legacy") minutes against \(configured)-minute setting")
    }
}

section("PomodoroDataStore.completedTodayCount")
do {
    let store = PomodoroDataStore.shared
    let before = store.completedTodayCount(workDuration: 25)

    store.add(PomodoroSession(startTime: Date(), taskDescription: "", completed: false,
                              pomodoroNumber: 1, plannedMinutes: 25))
    store.updateLast(endTime: Date(), completed: true)
    checkEqual(store.completedTodayCount(workDuration: 25), before + 1, "a full pomodoro adds to today")

    store.add(PomodoroSession(startTime: Date(), taskDescription: "", completed: false,
                              pomodoroNumber: 2, plannedMinutes: 10))
    store.updateLast(endTime: Date(), completed: true)
    checkEqual(store.completedTodayCount(workDuration: 25), before + 1, "a short pomodoro does not")

    store.add(PomodoroSession(startTime: Date(), taskDescription: "", completed: false,
                              pomodoroNumber: 3, plannedMinutes: 25))
    store.updateLast(endTime: Date(), completed: false)
    checkEqual(store.completedTodayCount(workDuration: 25), before + 1, "an abandoned pomodoro does not")

    store.add(PomodoroSession(startTime: Date().addingTimeInterval(-48 * 3600), taskDescription: "",
                              completed: false, pomodoroNumber: 4, plannedMinutes: 25))
    store.updateLast(endTime: Date().addingTimeInterval(-48 * 3600), completed: true)
    checkEqual(store.completedTodayCount(workDuration: 25), before + 1, "a pomodoro from two days ago does not")

    let before50 = store.completedTodayCount(workDuration: 50)
    let cases: [(Int?, Bool, Int)] = [
        (45, false, 0), (45, true, 1), (44, true, 1), (50, true, 2), (nil, true, 3),
    ]
    for (planned, completed, added) in cases {
        store.add(PomodoroSession(startTime: Date(), taskDescription: "", completed: false,
                                  pomodoroNumber: 1, plannedMinutes: planned))
        store.updateLast(endTime: Date(), completed: completed)
        checkEqual(store.completedTodayCount(workDuration: 50), before50 + added,
                   "daily total after \(planned.map(String.init) ?? "legacy") minutes, completed=\(completed)")
    }
}

section("A pomodoro started before plannedMinutes existed is backfilled on restore")
do {
    clearSaved()
    let store = PomodoroDataStore.shared
    UserDefaults.standard.set(50, forKey: "pomodoroWorkDuration")
    let before = store.completedTodayCount(workDuration: 50)

    // A short session as an older build would have written it: no plannedMinutes.
    let inFlight = PomodoroSession(startTime: Date().addingTimeInterval(-60), taskDescription: "",
                                   completed: false, pomodoroNumber: 1, plannedMinutes: nil)
    store.add(inFlight)
    setSavedState(phase: "work", startOffset: -60, duration: 11 * 60, task: "")

    let s = PomodoroScheduler()
    s.restoreState()
    checkEqual(store.fetchRecent(limit: 500).first { $0.id == inFlight.id }?.plannedMinutes, 11,
               "restore backfills the saved phase duration")

    store.updateLast(endTime: Date(), completed: true)
    checkEqual(store.completedTodayCount(workDuration: 50), before,
               "so the short in-flight pomodoro still doesn't count")
    clearSaved()
}

section("Backfill never overwrites a length the session already recorded")
do {
    clearSaved()
    let store = PomodoroDataStore.shared
    let recorded = PomodoroSession(startTime: Date().addingTimeInterval(-60), taskDescription: "",
                                   completed: false, pomodoroNumber: 1, plannedMinutes: 50)
    store.add(recorded)
    store.backfillLastPlannedMinutes(11)
    checkEqual(store.fetchRecent(limit: 500).first { $0.id == recorded.id }?.plannedMinutes, 50,
               "existing plannedMinutes is left alone")
}

section("S3 task storage: strict schema, safe writes, and recovery snapshots")
do {
    let row = TasksClient.newTaskRow(content: "Unicode 📝", id: "a", today: "2026-09-15")
    let original = try JSONEncoder().encode(TaskDocument(version: 1, rows: [row]))
    checkEqual(try TaskDocument.decode(original).rows, [row], "document round trips without losing fields")
    for data in [Data("{}".utf8), Data("broken".utf8),
                 try JSONEncoder().encode(TaskDocument(version: 2, rows: [])),
                 try JSONEncoder().encode(TaskDocument(version: 1, rows: [["short"]])),
                 try JSONEncoder().encode(TaskDocument(version: 1, rows: [row, row]))] {
        check((try? TaskDocument.decode(data)) == nil, "invalid schema never becomes an empty list")
    }
    for uri in ["", "https://example.com/key", "s3://bucket", "s3://bucket/", "s3://a@bucket/key", "s3://bucket/key?x"] {
        check((try? S3TaskStore.parseURI(uri)) == nil, "invalid S3 location is rejected")
    }
    checkEqual(try S3TaskStore.parseURI("s3://example-bucket/folder/tasks.json").key, "folder/tasks.json", "configured key is preserved")
    checkEqual(TaskStorageError.from(stderr: "ExpiredToken private-location").coachError.kind, "tasks-auth-required", "AWS expiration is actionable")
    check(!TaskStorageError.from(stderr: "AccessDenied private-location").coachError.detail.contains("private-location"), "AWS errors do not leak locations")

    var current = original
    var revision = 1
    var commands: [[String]] = []
    var backups: [Data] = []
    var conflictOnce = true
    let store = try S3TaskStore(uri: "s3://example-bucket/tasks.json", runner: { args in
        commands.append(args)
        let key = args[args.firstIndex(of: "--key")! + 1]
        if args[1] == "get-object" {
            let file = args[args.firstIndex(of: "--key")! + 2]
            try current.write(to: URL(fileURLWithPath: file))
            return (0, Data("{\"ETag\":\"revision-\(revision)\"}".utf8), Data())
        }
        let body = try Data(contentsOf: URL(fileURLWithPath: args[args.firstIndex(of: "--body")! + 1]))
        if key.contains(".history/") {
            check(args.contains("--if-none-match"), "history never overwrites another snapshot")
            backups.append(body)
        } else {
            check(args.contains("--if-match"), "task writes always have a precondition")
            if conflictOnce {
                conflictOnce = false
                var changed = try TaskDocument.decode(current)
                changed.rows[0][1] = "Concurrent edit"
                current = try JSONEncoder().encode(changed)
                revision += 1
                return (1, Data(), Data("PreconditionFailed".utf8))
            }
            checkEqual(args[args.firstIndex(of: "--if-match")! + 1], "revision-2", "retry uses the refreshed ETag")
            current = body
        }
        return (0, Data("{}".utf8), Data())
    })
    let added = TasksClient.newTaskRow(content: "New task", id: "b", today: "2026-09-15")
    try store.append(row: added)
    checkEqual(try TaskDocument.decode(current).rows.map { $0[0] }, ["a", "b"], "append occurs once across a conflict")
    checkEqual(try TaskDocument.decode(current).rows[0][1], "Concurrent edit", "concurrent task edits survive")
    checkEqual(backups.first, original, "previous data is archived before updating")
    checkEqual(commands.count, 6, "conflict retries read, archive, and conditional write")

    current = original
    var lostResponse = false
    let uncertain = try S3TaskStore(uri: "s3://example-bucket/tasks.json", runner: { args in
        let key = args[args.firstIndex(of: "--key")! + 1]
        if args[1] == "get-object" {
            try current.write(to: URL(fileURLWithPath: args[args.firstIndex(of: "--key")! + 2]))
            return (0, Data("{\"ETag\":\"etag\"}".utf8), Data())
        }
        if !key.contains(".history/") {
            current = try Data(contentsOf: URL(fileURLWithPath: args[args.firstIndex(of: "--body")! + 1]))
            lostResponse = true
            return (1, Data(), Data("connection reset".utf8))
        }
        return (0, Data("{}".utf8), Data())
    })
    try uncertain.append(row: added)
    check(lostResponse, "lost response path was exercised")
    checkEqual(try TaskDocument.decode(current).rows.count, 2, "readback confirms an uncertain write without duplicating it")
    checkEqual(TaskStorageError.from(stderr: "AccessDenied for AWSReservedSSO_Example").coachError.kind,
               "tasks-unavailable", "an SSO role ARN does not make an access denial an expired token")

    var writes = 0
    let broken = try S3TaskStore(uri: "s3://example-bucket/tasks.json", runner: { args in
        if args[1] == "get-object" { return (1, Data(), Data("NoSuchKey".utf8)) }
        writes += 1
        return (0, Data("{}".utf8), Data())
    })
    check((try? broken.append(row: added)) == nil, "missing objects require explicit initialization")
    checkEqual(writes, 0, "read failure never causes an empty replacement")
} catch {
    check(false, "S3 tests threw: \(error)")
}

section("BuildInfo: identify the installed source revision")
do {
    checkEqual(BuildInfo.label(info: [:]), "Build: unknown", "unstamped builds are explicitly unknown")
    checkEqual(BuildInfo.label(info: ["ExperienceSamplingGitCommit": ""]), "Build: unknown", "empty revisions are unknown")
    let info: [String: Any] = ["ExperienceSamplingGitCommit": "0123456789abcdef", "ExperienceSamplingGitDirty": false]
    checkEqual(BuildInfo.label(info: info), "Build: 0123456789ab", "clean builds show their revision")
    var modified = info
    modified["ExperienceSamplingGitDirty"] = true
    checkEqual(BuildInfo.label(info: modified), "Build: 0123456789ab (modified)", "local modifications are visible")
}

// MARK: - Summary

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
