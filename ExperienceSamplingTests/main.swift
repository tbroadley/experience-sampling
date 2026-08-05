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
        .modelNotEntitled("claude-sonnet-5"), .httpError(status: 500, detail: "x"), .badResponse("x")
    ]
    check(all.allSatisfy { !$0.title.isEmpty }, "all cases have a title")
    check(all.allSatisfy { !$0.advice.isEmpty }, "all cases have advice")
    check(Set(all.map(\.kind)).count == all.count, "kinds are distinct, so the throttle can't conflate them")
    check(!all.contains { $0.isAuthProblem && $0.isTransient }, "no case is both an auth problem and retried as transient")
}

// MARK: - Summary

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
