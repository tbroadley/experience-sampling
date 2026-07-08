import AppKit
import CoreAudio
import CoreMediaIO
import SwiftUI

// MARK: - Data Model

enum ResponseType: String, Codable {
    case startOfDay
    case intraday
}

struct Response: Codable, Identifiable {
    var id: UUID = UUID()
    var timestamp: Date
    var type: ResponseType
    var excitement: Int
    var activity: String?
}

// MARK: - Pomodoro Data Model

enum PomodoroPhase: String, Codable {
    case idle
    case work
    case shortBreak
    case longBreak
}

struct PomodoroSession: Codable, Identifiable {
    var id: UUID = UUID()
    var startTime: Date
    var endTime: Date?
    var taskDescription: String
    var completed: Bool
    var pomodoroNumber: Int  // 1-4, for tracking long break cycle
}

// MARK: - Simple JSON Storage

final class DataStore {
    static let shared = DataStore()

    private let fileURL: URL
    private var responses: [Response] = []

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ExperienceSampling", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("responses.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            responses = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([Response].self, from: data) else {
            responses = []
            return
        }
        responses = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(responses) else { return }
        try? data.write(to: fileURL)
    }

    func add(_ response: Response) {
        responses.append(response)
        save()
    }

    func fetchRecent(limit: Int = 50) -> [Response] {
        Array(responses.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    func exportCSV() -> URL {
        let formatter = ISO8601DateFormatter()
        var csv = "id,timestamp,type,excitement,activity\n"
        for r in responses.sorted(by: { $0.timestamp < $1.timestamp }) {
            let activity = r.activity?.replacingOccurrences(of: "\"", with: "\"\"") ?? ""
            csv += "\(r.id),\(formatter.string(from: r.timestamp)),\(r.type.rawValue),\(r.excitement),\"\(activity)\"\n"
        }
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("experience-sampling-export.csv")
        try? csv.write(to: exportURL, atomically: true, encoding: .utf8)
        return exportURL
    }
}

// MARK: - Pomodoro Data Store

final class PomodoroDataStore {
    static let shared = PomodoroDataStore()

    private let fileURL: URL
    private var sessions: [PomodoroSession] = []

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ExperienceSampling", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("pomodoro-sessions.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            sessions = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([PomodoroSession].self, from: data) else {
            sessions = []
            return
        }
        sessions = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: fileURL)
    }

    func add(_ session: PomodoroSession) {
        sessions.append(session)
        save()
    }

    func updateLast(endTime: Date, completed: Bool) {
        guard !sessions.isEmpty else { return }
        sessions[sessions.count - 1].endTime = endTime
        sessions[sessions.count - 1].completed = completed
        save()
    }

    func fetchRecent(limit: Int = 50) -> [PomodoroSession] {
        Array(sessions.sorted { $0.startTime > $1.startTime }.prefix(limit))
    }

    func completedTodayCount() -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return sessions.filter { $0.completed && calendar.startOfDay(for: $0.startTime) == today }.count
    }

    func exportCSV() -> URL {
        let formatter = ISO8601DateFormatter()
        var csv = "id,start_time,end_time,task,completed,pomodoro_number\n"
        for s in sessions.sorted(by: { $0.startTime < $1.startTime }) {
            let task = s.taskDescription.replacingOccurrences(of: "\"", with: "\"\"")
            let endTime = s.endTime.map { formatter.string(from: $0) } ?? ""
            csv += "\(s.id),\(formatter.string(from: s.startTime)),\(endTime),\"\(task)\",\(s.completed),\(s.pomodoroNumber)\n"
        }
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("pomodoro-export.csv")
        try? csv.write(to: exportURL, atomically: true, encoding: .utf8)
        return exportURL
    }
}

// MARK: - Prompt Scheduler

final class PromptScheduler: ObservableObject {
    private var timers: [Timer] = []
    private var wakeObservers: [Any] = []
    var onPromptTriggered: (() -> Void)?

    var workingHoursStart: Int { UserDefaults.standard.integer(forKey: "workingHoursStart").nonZeroOr(9) }
    var workingHoursEnd: Int { UserDefaults.standard.integer(forKey: "workingHoursEnd").nonZeroOr(17) }
    var averagePromptsPerDay: Double { UserDefaults.standard.double(forKey: "averagePromptsPerDay").nonZeroOr(3.0) }

    func start() {
        schedulePromptsForToday()
        let nc = NSWorkspace.shared.notificationCenter
        wakeObservers = [
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.schedulePromptsForToday()
            },
            nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.schedulePromptsForToday()
            }
        ]
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        timers = []
        let nc = NSWorkspace.shared.notificationCenter
        wakeObservers.forEach { nc.removeObserver($0) }
        wakeObservers = []
    }

    private func schedulePromptsForToday() {
        timers.forEach { $0.invalidate() }
        timers = []

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        let startOfWork = calendar.date(bySettingHour: workingHoursStart, minute: 0, second: 0, of: today)!
        let endOfWork = calendar.date(bySettingHour: workingHoursEnd, minute: 0, second: 0, of: today)!

        let effectiveStart = max(now, startOfWork)
        guard effectiveStart < endOfWork else {
            scheduleNextDayStart()
            return
        }

        let totalWorkingSeconds = endOfWork.timeIntervalSince(startOfWork)
        let remainingSeconds = endOfWork.timeIntervalSince(effectiveStart)
        let remainingFraction = remainingSeconds / totalWorkingSeconds
        let promptCount = max(Int(round(averagePromptsPerDay * remainingFraction)), 0)

        if promptCount > 0 {
            var promptTimes: [Date] = (0..<promptCount).map { _ in
                effectiveStart.addingTimeInterval(Double.random(in: 0..<remainingSeconds))
            }.sorted()

            let minGap: TimeInterval = 10 * 60
            for i in 1..<promptTimes.count where promptTimes[i].timeIntervalSince(promptTimes[i - 1]) < minGap {
                promptTimes[i] = promptTimes[i - 1].addingTimeInterval(minGap)
            }

            for time in promptTimes where time < endOfWork {
                let interval = time.timeIntervalSince(now)
                guard interval > 0 else { continue }
                let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                    self?.onPromptTriggered?()
                }
                timers.append(timer)
            }
        }

        let endTimer = Timer.scheduledTimer(withTimeInterval: endOfWork.timeIntervalSince(now) + 1, repeats: false) { [weak self] _ in
            self?.scheduleNextDayStart()
        }
        timers.append(endTimer)
    }

    private func scheduleNextDayStart() {
        let calendar = Calendar.current
        let now = Date()
        var nextStart = calendar.date(bySettingHour: workingHoursStart, minute: 0, second: 0, of: now)!
        if nextStart <= now { nextStart = calendar.date(byAdding: .day, value: 1, to: nextStart)! }

        let timer = Timer.scheduledTimer(withTimeInterval: nextStart.timeIntervalSince(now), repeats: false) { [weak self] _ in
            self?.schedulePromptsForToday()
        }
        timers.append(timer)
    }
}

// MARK: - Pomodoro Scheduler

final class PomodoroScheduler: ObservableObject {
    @Published var phase: PomodoroPhase = .idle
    @Published var timeRemaining: Int = 0
    @Published var pomodoroCount: Int = 0  // cycles 1-4

    var workDuration: Int { UserDefaults.standard.integer(forKey: "pomodoroWorkDuration").nonZeroOr(25) }
    var shortBreakDuration: Int { UserDefaults.standard.integer(forKey: "pomodoroShortBreak").nonZeroOr(5) }
    var longBreakDuration: Int { UserDefaults.standard.integer(forKey: "pomodoroLongBreak").nonZeroOr(15) }
    var snoozeDuration: Int { UserDefaults.standard.integer(forKey: "pomodoroSnooze").nonZeroOr(5) }
    var breakSnoozeDuration: Int { UserDefaults.standard.integer(forKey: "pomodoroBreakSnooze").nonZeroOr(5) }

    private var displayTimer: Timer?
    private var snoozeTimer: Timer?
    private var breakSnoozeTimer: Timer?
    private var phaseStartDate: Date?
    private var phaseDuration: Int = 0

    private let phaseKey = "pomodoroPhase"
    private let phaseStartKey = "pomodoroPhaseStart"
    private let phaseDurationKey = "pomodoroPhaseDuration"
    // Previous misspelling of phaseDurationKey, kept only for one-time migration
    // of state saved by older builds (see migrateLegacyKeys).
    private let legacyPhaseDurationKey = "pommadoroPhaseDuration"
    // No longer written; still cleared so stale state from older builds goes away.
    private let taskKey = "pomodoroTask"
    private let countKey = "pomodoroCount"

    var onTimerTick: ((Int, PomodoroPhase) -> Void)?
    var onWorkSessionEnd: (() -> Void)?
    var onBreakStart: (() -> Void)?
    var onBreakEnd: (() -> Void)?
    var onSnoozeEnd: (() -> Void)?
    var onBreakSnoozeEnd: (() -> Void)?
    var onWorkStart: (() -> Void)?

    init() {
        migrateLegacyKeys()
        pomodoroCount = UserDefaults.standard.integer(forKey: countKey)
    }

    // Move any phase duration saved under the old misspelled key to the correct
    // one so an in-progress session survives the upgrade, then drop the old key.
    private func migrateLegacyKeys() {
        let d = UserDefaults.standard
        if d.object(forKey: legacyPhaseDurationKey) != nil {
            if d.object(forKey: phaseDurationKey) == nil {
                d.set(d.integer(forKey: legacyPhaseDurationKey), forKey: phaseDurationKey)
            }
            d.removeObject(forKey: legacyPhaseDurationKey)
        }
    }

    func restoreState() {
        guard let phaseRaw = UserDefaults.standard.string(forKey: phaseKey),
              let savedPhase = PomodoroPhase(rawValue: phaseRaw),
              savedPhase != .idle,
              let phaseStart = UserDefaults.standard.object(forKey: phaseStartKey) as? Date else {
            return
        }

        let duration = UserDefaults.standard.integer(forKey: phaseDurationKey)
        let elapsed = Int(Date().timeIntervalSince(phaseStart))
        let remaining = duration - elapsed

        if remaining > 0 {
            phase = savedPhase
            phaseStartDate = phaseStart
            phaseDuration = duration
            timeRemaining = remaining
            startDisplayTimer()
            if savedPhase == .work { onWorkStart?() } else { onBreakStart?() }
        } else {
            clearSavedState()
            if savedPhase == .work {
                PomodoroDataStore.shared.updateLast(endTime: phaseStart.addingTimeInterval(Double(duration)), completed: true)
                onWorkSessionEnd?()
            } else {
                onBreakEnd?()
            }
        }
    }

    private func saveState() {
        UserDefaults.standard.set(phase.rawValue, forKey: phaseKey)
        UserDefaults.standard.set(phaseStartDate ?? Date(), forKey: phaseStartKey)
        UserDefaults.standard.set(phaseDuration, forKey: phaseDurationKey)
        UserDefaults.standard.set(pomodoroCount, forKey: countKey)
    }

    private func clearSavedState() {
        UserDefaults.standard.removeObject(forKey: phaseKey)
        UserDefaults.standard.removeObject(forKey: phaseStartKey)
        UserDefaults.standard.removeObject(forKey: phaseDurationKey)
        UserDefaults.standard.removeObject(forKey: taskKey)
    }

    var workDurationOverride: Int?

    func startWork() {
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        pomodoroCount = (pomodoroCount % 4) + 1
        phase = .work
        let effectiveDuration = workDurationOverride ?? workDuration
        workDurationOverride = nil
        phaseDuration = effectiveDuration * 60
        timeRemaining = phaseDuration
        phaseStartDate = Date()

        // The per-pomodoro goal is gone; the focus coach now tracks the top
        // Todoist to-do live, so sessions are recorded without a fixed task.
        PomodoroDataStore.shared.add(PomodoroSession(
            startTime: Date(),
            taskDescription: "",
            completed: false,
            pomodoroNumber: pomodoroCount
        ))

        saveState()
        startDisplayTimer()
        onWorkStart?()
    }

    func startBreak(isLong: Bool) {
        phase = isLong ? .longBreak : .shortBreak
        phaseDuration = (isLong ? longBreakDuration : shortBreakDuration) * 60
        timeRemaining = phaseDuration
        phaseStartDate = Date()
        saveState()
        startDisplayTimer()
        onBreakStart?()
    }

    func abandon() {
        phase = .idle
        stopDisplayTimer()
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        breakSnoozeTimer?.invalidate()
        breakSnoozeTimer = nil
        clearSavedState()
        PomodoroDataStore.shared.updateLast(endTime: Date(), completed: false)
        onTimerTick?(0, .idle)
    }

    /// Finalize a completed work session that won't be followed by a break — e.g.
    /// a meeting or lunch is starting, so we skip the break entirely. When the
    /// work timer hits zero the scheduler fires `onWorkSessionEnd` but leaves
    /// `phase == .work` (the break modal normally moves it forward); this returns
    /// it cleanly to idle. Unlike `abandon`, it does not record the session as
    /// incomplete — it was already recorded `completed` when the timer expired.
    func endToIdle() {
        phase = .idle
        stopDisplayTimer()
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        breakSnoozeTimer?.invalidate()
        breakSnoozeTimer = nil
        clearSavedState()
        onTimerTick?(0, .idle)
    }

    func scheduleSnooze() {
        snoozeTimer?.invalidate()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: Double(snoozeDuration * 60), repeats: false) { [weak self] _ in
            self?.onSnoozeEnd?()
        }
    }

    func scheduleBreakSnooze() {
        breakSnoozeTimer?.invalidate()
        breakSnoozeTimer = Timer.scheduledTimer(withTimeInterval: Double(breakSnoozeDuration * 60), repeats: false) { [weak self] _ in
            self?.onBreakSnoozeEnd?()
        }
    }

    var isBreakSnoozePending: Bool { breakSnoozeTimer != nil }

    func cancelBreakSnooze() {
        breakSnoozeTimer?.invalidate()
        breakSnoozeTimer = nil
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        onTimerTick?(timeRemaining, phase)
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.phaseStartDate else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            self.timeRemaining = max(self.phaseDuration - elapsed, 0)
            self.onTimerTick?(self.timeRemaining, self.phase)

            if self.timeRemaining <= 0 {
                self.stopDisplayTimer()
                self.clearSavedState()
                if self.phase == .work {
                    PomodoroDataStore.shared.updateLast(endTime: Date(), completed: true)
                    self.onWorkSessionEnd?()
                } else {
                    self.phase = .idle
                    self.onBreakEnd?()
                }
            }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    func isLongBreakDue() -> Bool {
        pomodoroCount == 4
    }

    func resetBreakCycle() {
        pomodoroCount = 0
        UserDefaults.standard.set(pomodoroCount, forKey: countKey)
    }

    func formattedTime() -> String {
        let mins = timeRemaining / 60
        let secs = timeRemaining % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Wake Detector

final class WakeDetector {
    private let lastPomodoroPromptDateKey = "lastPomodoroStartOfDayPromptDate"
    var onNewPomodoroDay: (() -> Void)?
    var shouldSuppressPomodoroPrompt: (() -> Bool)?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkForNewDay()
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkForNewDay()
        }
    }

    func checkForNewDay() {
        UserDefaults.standard.synchronize()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let hour = calendar.component(.hour, from: Date())

        // Only show "Good morning" prompts before noon
        guard hour < 12 else { return }

        let lastPomodoroDate = UserDefaults.standard.object(forKey: lastPomodoroPromptDateKey) as? Date
        let lastPomodoroDay = lastPomodoroDate.map { calendar.startOfDay(for: $0) }
        if lastPomodoroDay != today && shouldSuppressPomodoroPrompt?() != true {
            onNewPomodoroDay?()
        }
    }

    func markPomodoroPrompted() {
        UserDefaults.standard.set(Date(), forKey: lastPomodoroPromptDateKey)
    }

    func resetPomodoro() {
        UserDefaults.standard.removeObject(forKey: lastPomodoroPromptDateKey)
    }
}

// MARK: - Break Caffeinator

/// Keeps the Mac awake during pomodoros and breaks, mirroring the `caf` Alfred
/// shortcut (`caffeinate -i`) — but never indefinitely.
///
/// - During a **work** session we only caffeinate while the screen is locked
///   (the user stepped away). When they're present the machine won't idle-sleep
///   on its own, so there's nothing to prevent.
/// - During a **break** we caffeinate regardless of lock state, and if the break
///   ends while the screen is locked we keep the machine awake until the user
///   returns (unlock) so the next-pomodoro prompt isn't missed to a sleep.
/// - In every case a **1-hour away cap** wins: once the screen has been locked
///   continuously for `awayCap`, we stop caffeinating so a break (or work
///   session) the user never returns from doesn't keep the Mac awake overnight.
///   Unlocking resets the clock.
final class BreakCaffeinator {
    enum Mode: Equatable {
        case off            // idle: do not caffeinate
        case work           // work session: caffeinate only while locked
        case onBreak        // break: caffeinate while away
        case awaitingReturn // break ended while away: caffeinate until unlock
    }

    private(set) var mode: Mode = .off
    private(set) var awayCapReached = false
    private var process: Process?
    private var awayTimer: Timer?
    private let awayCap: TimeInterval
    private let isScreenLocked: () -> Bool
    // Test seam: when set, replaces spawning the real `caffeinate` process.
    private let onSetCaffeinated: ((Bool) -> Void)?

    init(awayCap: TimeInterval = 60 * 60,
         isScreenLocked: @escaping () -> Bool = BreakCaffeinator.systemScreenLocked,
         onSetCaffeinated: ((Bool) -> Void)? = nil) {
        self.awayCap = awayCap
        self.isScreenLocked = isScreenLocked
        self.onSetCaffeinated = onSetCaffeinated
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.screenDidLock() }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.screenDidUnlock() }
    }

    // MARK: - Phase hooks (called from the app on pomodoro transitions)

    func workStarted() { mode = .work; evaluate() }

    func breakStarted() { mode = .onBreak; evaluate() }

    func breakEnded() {
        // If the user is away when the break ends, stay awake until they return
        // (subject to the away cap); otherwise stop now.
        mode = isScreenLocked() ? .awaitingReturn : .off
        evaluate()
    }

    func sessionEnded() { mode = .off; evaluate() }

    // MARK: - Decision

    /// Pure decision: should `caffeinate` be running right now?
    static func shouldCaffeinate(mode: Mode, locked: Bool, capReached: Bool) -> Bool {
        if capReached { return false }
        switch mode {
        case .off: return false
        case .onBreak: return true
        case .work, .awaitingReturn: return locked
        }
    }

    /// Screen-event handlers. Exposed (non-private) so headless tests can drive
    /// lock/unlock transitions with an injected lock state.
    func screenDidLock() { evaluate() }

    func screenDidUnlock() {
        // The user is back: an "awaiting return" caffeination has done its job.
        if mode == .awaitingReturn { mode = .off }
        evaluate()
    }

    /// Invoked when the screen has been locked for `awayCap`. Exposed (non-private)
    /// so headless tests can trigger it without waiting on the real timer.
    func handleAwayCapElapsed() {
        awayTimer = nil
        awayCapReached = true
        evaluate()
    }

    private func evaluate() {
        let locked = isScreenLocked()
        // The away clock is driven purely by lock state: arm it while locked,
        // and reset it (and the cap) the moment the screen is unlocked.
        if locked {
            if awayTimer == nil && !awayCapReached {
                awayTimer = Timer.scheduledTimer(withTimeInterval: awayCap, repeats: false) { [weak self] _ in
                    self?.handleAwayCapElapsed()
                }
            }
        } else {
            awayTimer?.invalidate()
            awayTimer = nil
            awayCapReached = false
        }

        setCaffeinated(BreakCaffeinator.shouldCaffeinate(mode: mode, locked: locked, capReached: awayCapReached))
    }

    private func setCaffeinated(_ on: Bool) {
        if let onSetCaffeinated {
            onSetCaffeinated(on)
            return
        }
        if on { startCaffeinate() } else { stopCaffeinate() }
    }

    private func startCaffeinate() {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -i: prevent idle system sleep (matches the Alfred shortcut).
        // -w <pid>: self-terminate if this app dies, so we never orphan a
        // caffeinate that keeps the Mac awake forever.
        p.arguments = ["-i", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.process = nil }
        }
        do { try p.run(); process = p } catch { process = nil }
    }

    private func stopCaffeinate() {
        process?.terminate()
        process = nil
    }

    static func systemScreenLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Int) == 1
    }
}

// MARK: - Calendar Monitor

struct CalendarEvent {
    let summary: String
    let start: Date
    let end: Date
    let meetLink: String?
    let declined: Bool
}

final class CalendarMonitor {
    private var events: [CalendarEvent] = []
    private var refreshTimer: Timer?
    private var meetLinkTimers: [Timer] = []
    private var openedMeetLinks: Set<String> = []
    private var avInactiveCount = 0
    private var earlyExitMeetings: Set<String> = []
    private var avCheckTimer: Timer?
    private let refreshInterval: TimeInterval = 5 * 60
    private let meetOpenBuffer: TimeInterval = 60
    private let avChecksBeforeEarlyExit = 2

    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        avCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkAVForEarlyExit()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        avCheckTimer?.invalidate()
        avCheckTimer = nil
        meetLinkTimers.forEach { $0.invalidate() }
        meetLinkTimers = []
    }

    private var acceptedEvents: [CalendarEvent] { events.filter { !$0.declined } }

    func isInMeeting(at date: Date = Date()) -> Bool {
        guard let meeting = acceptedEvents.first(where: { date >= $0.start && date < $0.end }) else { return false }
        let meetingKey = "\(meeting.start.timeIntervalSince1970)"
        return !earlyExitMeetings.contains(meetingKey)
    }

    /// Like `isInMeeting`, but only counts events that are actually video meetings
    /// (have a Meet/conference link). The meeting-attention monitor uses this so
    /// non-meeting calendar blocks — "Lunch", phone appointments — don't read as
    /// meetings; combined with Wispr Flow holding the mic, they would otherwise
    /// fire spurious drift nudges.
    func isInVideoMeeting(at date: Date = Date()) -> Bool {
        guard let meeting = acceptedEvents.first(where: {
            date >= $0.start && date < $0.end && !($0.meetLink ?? "").isEmpty
        }) else { return false }
        let meetingKey = "\(meeting.start.timeIntervalSince1970)"
        return !earlyExitMeetings.contains(meetingKey)
    }

    private func checkAVForEarlyExit() {
        let now = Date()
        guard let meeting = acceptedEvents.first(where: { now >= $0.start && now < $0.end }) else {
            avInactiveCount = 0
            return
        }
        let meetingKey = "\(meeting.start.timeIntervalSince1970)"
        let avActive = Self.isCameraRunning() || Self.isMicRunning()

        if earlyExitMeetings.contains(meetingKey) {
            if avActive {
                earlyExitMeetings.remove(meetingKey)
                avInactiveCount = 0
            }
            return
        }

        let elapsed = now.timeIntervalSince(meeting.start)
        guard elapsed > 120 else { return }

        if avActive {
            avInactiveCount = 0
        } else {
            avInactiveCount += 1
            if avInactiveCount >= avChecksBeforeEarlyExit {
                earlyExitMeetings.insert(meetingKey)
                avInactiveCount = 0
            }
        }
    }

    static func isCameraRunning() -> Bool {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: count)
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, dataSize, &dataSize, &devices)

        for device in devices {
            var isRunningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var isRunning: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            CMIOObjectGetPropertyData(device, &isRunningAddress, 0, nil, size, &size, &isRunning)
            if isRunning != 0 { return true }
        }
        return false
    }

    static func isMicRunning() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return false }
        var devices = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &devices)

        for device in devices {
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            let result = AudioObjectGetPropertyDataSize(device, &inputAddress, 0, nil, &inputSize)
            guard result == 0 && inputSize > 0 else { continue }

            var isRunningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunning: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(device, &isRunningAddress, 0, nil, &size, &isRunning)
            if isRunning != 0 { return true }
        }
        return false
    }

    func minutesUntilNextMeeting(from date: Date = Date()) -> Int? {
        let upcoming = acceptedEvents.filter { $0.start > date }.sorted { $0.start < $1.start }
        guard let next = upcoming.first else { return nil }
        return Int(next.start.timeIntervalSince(date) / 60)
    }

    func currentMeetingEnd(at date: Date = Date()) -> Date? {
        acceptedEvents.first { date >= $0.start && date < $0.end }?.end
    }

    /// The event we're currently in, or the next one starting within `minutes`.
    /// Used at pomodoro end to decide whether a break should be offered: a video
    /// meeting (has a meet link) means stay silent, a non-video block ("Lunch")
    /// means show a notice. `acceptedEvents` already excludes non-`default`
    /// event types (focusTime, working-location), so those never count.
    func currentOrImminentEvent(within minutes: Int, from date: Date = Date()) -> CalendarEvent? {
        if let current = acceptedEvents.first(where: {
            date >= $0.start && date < $0.end
            && !earlyExitMeetings.contains("\($0.start.timeIntervalSince1970)")
        }) {
            return current
        }
        let horizon = date.addingTimeInterval(Double(minutes) * 60)
        return acceptedEvents
            .filter { $0.start > date && $0.start <= horizon }
            .min { $0.start < $1.start }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let now = Date()
            let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now)!

            let process = Process()
            let gws = Self.findGws()
            process.executableURL = URL(fileURLWithPath: gws)
            process.arguments = [
                "calendar", "events", "list",
                "--params", """
                {"calendarId":"primary","timeMin":"\(formatter.string(from: now))","timeMax":"\(formatter.string(from: endOfDay))","singleEvents":true,"orderBy":"startTime","maxResults":"20"}
                """
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch { return }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { return }

            let parsed: [CalendarEvent] = items.compactMap { item in
                guard let startObj = item["start"] as? [String: String],
                      let endObj = item["end"] as? [String: String] else { return nil }

                let startStr = startObj["dateTime"]
                let endStr = endObj["dateTime"]
                guard let startStr, let endStr,
                      let start = formatter.date(from: startStr),
                      let end = formatter.date(from: endStr) else { return nil }

                let summary = item["summary"] as? String ?? "(no title)"
                let hangout = item["hangoutLink"] as? String
                let videoEntry = (((item["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]])?
                    .first { $0["entryPointType"] as? String == "video" })?["uri"] as? String
                let meetLink = hangout ?? videoEntry
                let eventType = item["eventType"] as? String ?? "default"
                if eventType != "default" { return nil }
                let attendees = item["attendees"] as? [[String: Any]] ?? []
                let declined = attendees.first { $0["self"] as? Bool == true }?["responseStatus"] as? String == "declined"
                return CalendarEvent(summary: summary, start: start, end: end, meetLink: meetLink, declined: declined)
            }

            DispatchQueue.main.async {
                self.events = parsed
                self.scheduleMeetLinkOpeners()
            }
        }
    }

    private func scheduleMeetLinkOpeners() {
        meetLinkTimers.forEach { $0.invalidate() }
        meetLinkTimers = []

        let now = Date()
        for event in acceptedEvents {
            guard let link = event.meetLink, !link.isEmpty else { continue }

            let openKey = "\(link)_\(event.start.timeIntervalSince1970)"
            guard !openedMeetLinks.contains(openKey) else { continue }

            let openTime = event.start.addingTimeInterval(-meetOpenBuffer)
            let delay = openTime.timeIntervalSince(now)
            guard delay > 0 else { continue }

            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.openedMeetLinks.insert(openKey)
                if let url = URL(string: link) {
                    NSWorkspace.shared.open(url)
                }
            }
            meetLinkTimers.append(timer)
        }
    }

    private static func findGws() -> String {
        let candidates = [
            "/Users/thomas/.nvm/versions/node/v24.12.0/bin/gws",
            "/usr/local/bin/gws",
            "/opt/homebrew/bin/gws"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "/usr/local/bin/gws"
    }
}

// MARK: - Focus Monitor

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatRole
    let text: String

    enum ChatRole { case assistant, user }
}

struct ScreenObservation {
    let timestamp: Date
    let context: String
}

// MARK: - Todoist

struct TodoistTask {
    let id: String
    let content: String
    let dayOrder: Int
}

struct TodoistCompletedTask {
    let content: String
    let completedAt: Date
}

enum TopTodo {
    case todo(TodoistTask)
    case none         // token works, but no qualifying to-do for today
    case unavailable  // no token, or the fetch failed — don't nag about it
}

// Reads today's top to-do from Todoist, the same source status-dashboard writes
// its ordering to: reordering there persists to the `day_order` field via the
// Sync API, so the lowest day_order among today's incomplete tasks is "the top".
enum TodoistClient {
    static var tokenFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ExperienceSampling/todoist-api-token.txt")
    }

    static func readToken() -> String? {
        guard let token = try? String(contentsOf: tokenFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return token
    }

    // Mirrors status-dashboard's get_tasks_for_date(today): incomplete, not
    // deleted, with a due date on or before today (overdue included), ordered by
    // day_order ascending.
    static func fetchTopTodo(completion: @escaping (TopTodo) -> Void) {
        guard let token = readToken() else { completion(.unavailable); return }

        var request = URLRequest(url: URL(string: "https://api.todoist.com/api/v1/sync")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // resource_types=["items"], percent-encoded.
        request.httpBody = Data("sync_token=*&resource_types=%5B%22items%22%5D".utf8)
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, error == nil,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                completion(.unavailable)
                return
            }

            let today = todayString()
            let candidates: [TodoistTask] = items.compactMap { item in
                if (item["checked"] as? Bool ?? false) || (item["is_deleted"] as? Bool ?? false) { return nil }
                guard let due = item["due"] as? [String: Any],
                      let dueRaw = due["date"] as? String, !dueRaw.isEmpty else { return nil }
                guard String(dueRaw.prefix(10)) <= today else { return nil }
                guard let id = item["id"] as? String, let content = item["content"] as? String else { return nil }
                return TodoistTask(id: id, content: content, dayOrder: item["day_order"] as? Int ?? 0)
            }

            guard let top = candidates.min(by: { $0.dayOrder < $1.dayOrder }) else {
                completion(.none)
                return
            }
            completion(.todo(top))
        }.resume()
    }

    // Today's completed to-dos (most recent first). Used to tell the focus coach
    // that time already spent on a finished to-do is a success, not a distraction —
    // so it doesn't scold the user for e.g. an hour on Slack that *was* the
    // (now-completed) "catch up on Slack" to-do. Failures return [] silently.
    static func fetchCompletedTodosToday(completion: @escaping ([TodoistCompletedTask]) -> Void) {
        guard let token = readToken() else { completion([]); return }

        let startOfDay = Calendar(identifier: .gregorian).startOfDay(for: Date())
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]

        var comps = URLComponents(string: "https://api.todoist.com/api/v1/tasks/completed/by_completion_date")!
        comps.queryItems = [
            URLQueryItem(name: "since", value: stamp.string(from: startOfDay)),
            URLQueryItem(name: "until", value: stamp.string(from: Date()))
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, error == nil,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                completion([])
                return
            }

            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let tasks: [TodoistCompletedTask] = items.compactMap { item in
                guard let content = item["content"] as? String,
                      let completedRaw = item["completed_at"] as? String,
                      let completedAt = parser.date(from: completedRaw) else { return nil }
                return TodoistCompletedTask(content: content, completedAt: completedAt)
            }
            completion(tasks.sorted { $0.completedAt > $1.completedAt })
        }.resume()
    }

    static func createTask(content: String, completion: @escaping (Bool) -> Void) {
        guard let token = readToken() else { completion(false); return }
        var request = URLRequest(url: URL(string: "https://api.todoist.com/api/v1/tasks")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["content": content, "due_string": "today"])
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { _, response, error in
            let ok = error == nil && ((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
            completion(ok)
        }.resume()
    }

    private static func todayString() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

final class FocusMonitor {
    private var timer: Timer?
    private var isShowingIntervention = false
    private var isChecking = false
    private var conversationHistory: [[String: Any]] = []
    private var pastSessions: [[[String: Any]]] = []
    private var screenHistory: [ScreenObservation] = []
    private var endorsedContexts: [String] = []
    private var lastDetectedContext: String = ""
    private var lastNoTodoPrompt: Date?

    enum Mode { case offTask, noTodo }
    private var mode: Mode = .offTask

    var checkInterval: TimeInterval { Double(UserDefaults.standard.integer(forKey: "focusCheckInterval").nonZeroOr(30)) }
    var isEnabled: Bool {
        let val = UserDefaults.standard.object(forKey: "focusMonitorEnabled")
        return (val as? Bool) ?? true
    }

    // The Claude model used for classification and coaching. Configurable in
    // Settings → Focus; defaults to Sonnet 5.
    static let defaultModel = "claude-sonnet-5"
    var model: String {
        let stored = UserDefaults.standard.string(forKey: "focusModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty == false ? stored! : Self.defaultModel)
    }

    // The current top Todoist to-do, re-fetched on every check.
    private var currentTopTodo: String = ""
    // Today's completed to-dos, re-fetched on every check. Given to the coach so it
    // credits time already spent on finished work instead of scolding for it.
    private var recentlyCompletedTodos: [TodoistCompletedTask] = []
    var onOffTaskDetected: ((String) -> Void)?
    // Fired when a check finds the user still off-task while the coach modal is
    // already open, so the coach can append a fresh nudge to the live conversation.
    var onFollowUpMessage: ((String) -> Void)?
    var onTopTodoChanged: ((String?) -> Void)?
    // Seconds left in the current work pomodoro, or nil if not in a work phase.
    // Wired to PomodoroScheduler so the coach knows how much time remains.
    var workTimeRemaining: (() -> Int?)?

    // True while a user-sent message is being answered, so background focus checks
    // don't append a follow-up on top of the reply the user is waiting for.
    private var isRespondingToUser = false

    func start() {
        guard isEnabled else { return }
        currentTopTodo = ""
        recentlyCompletedTodos = []
        mode = .offTask
        isShowingIntervention = false
        isChecking = false
        isRespondingToUser = false
        conversationHistory = []
        pastSessions = []
        screenHistory = []
        endorsedContexts = []
        lastDetectedContext = ""
        lastNoTodoPrompt = nil
        requestAccessibilityIfNeeded()
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func resumeAfterIntervention() {
        isShowingIntervention = false
        isRespondingToUser = false
        if !conversationHistory.isEmpty {
            pastSessions.append(conversationHistory)
        }
        conversationHistory = []
    }

    func endorseCurrentContext() {
        if !lastDetectedContext.isEmpty {
            endorsedContexts.append(lastDetectedContext)
        }
        isShowingIntervention = false
        isRespondingToUser = false
        conversationHistory = []
    }

    private func recordScreen(_ context: String) {
        screenHistory.append(ScreenObservation(timestamp: Date(), context: context))
    }

    private func recentScreenSummary() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        let start = screenHistory.startIndex
        let recent = screenHistory[start...]

        var runs: [(context: String, from: Date, to: Date)] = []
        for obs in recent {
            if let last = runs.last, last.context == obs.context {
                runs[runs.count - 1] = (last.context, last.from, obs.timestamp)
            } else {
                runs.append((obs.context, obs.timestamp, obs.timestamp))
            }
        }

        let lines = runs.suffix(15).map { run in
            let duration = Int(run.to.timeIntervalSince(run.from))
            let durStr = duration > 0 ? " (\(duration)s)" : ""
            return "  \(formatter.string(from: run.from))\(durStr) — \(run.context)"
        }
        return lines.joined(separator: "\n")
    }

    // Formats today's completed to-dos with a rough "how long ago" so the coach can
    // credit recently-finished work. Empty string when there are none.
    private func completedTodosSummary() -> String {
        guard !recentlyCompletedTodos.isEmpty else { return "" }
        let now = Date()
        let lines = recentlyCompletedTodos.prefix(10).map { task -> String in
            let mins = Int(now.timeIntervalSince(task.completedAt) / 60)
            let ago = mins < 1 ? "just now" : (mins < 60 ? "\(mins)m ago" : "\(mins / 60)h\(mins % 60)m ago")
            return "  - \"\(task.content)\" (completed \(ago))"
        }
        return lines.joined(separator: "\n")
    }

    // Wall-clock stamp (HH:mm:ss) shown next to each message so the coach can feel
    // how much time is elapsing between turns and versus now.
    static func clockStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func conversationLines(_ session: [[String: Any]]) -> [String] {
        var lines: [String] = []
        for msg in session {
            let role = msg["role"] as? String ?? "?"
            let stamp = (msg["ts"] as? Date).map { "[\(Self.clockStamp($0))] " } ?? ""
            if role == "assistant" {
                let text: String
                if let content = msg["content"] as? [[String: Any]] {
                    text = content.compactMap { $0["text"] as? String }.joined()
                } else if let content = msg["content"] as? String {
                    text = content
                } else { continue }
                if !text.isEmpty { lines.append("  \(stamp)Coach: \(text)") }
            } else if role == "user" {
                if let content = msg["content"] as? String {
                    lines.append("  \(stamp)User: \(content)")
                }
            }
        }
        return lines
    }

    private func pastSessionsSummary() -> String {
        guard !pastSessions.isEmpty else { return "" }
        var parts: [String] = []
        for (i, session) in pastSessions.enumerated() {
            let lines = conversationLines(session)
            if !lines.isEmpty {
                parts.append("Session \(i + 1):\n\(lines.joined(separator: "\n"))")
            }
        }
        return parts.joined(separator: "\n")
    }

    // The coaching exchange in the currently-open modal, for follow-up checks so the
    // coach can see what it has already said and not repeat itself.
    private func currentConversationSummary() -> String {
        conversationLines(conversationHistory).joined(separator: "\n")
    }

    // Human-readable time left in the current pomodoro, e.g. "20 min 30 sec".
    // Empty when we can't tell (not in a work phase).
    private func timeRemainingText() -> String {
        guard let seconds = workTimeRemaining?(), seconds > 0 else { return "" }
        let mins = seconds / 60
        let secs = seconds % 60
        if mins == 0 { return "\(secs) sec" }
        if secs == 0 { return "\(mins) min" }
        return "\(mins) min \(secs) sec"
    }

    private var conversationTools: [[String: Any]] {
        [["name": "create_todo",
          "description": "Add a new to-do to the user's Todoist list for today. Use this when the user tells you what they want to work on so it becomes part of their list.",
          "input_schema": [
            "type": "object",
            "properties": ["content": ["type": "string", "description": "The to-do text"]],
            "required": ["content"]
          ]]]
    }

    func sendMessage(userText: String, completion: @escaping (String) -> Void) {
        isRespondingToUser = true
        conversationHistory.append(["role": "user", "content": userText, "ts": Date()])

        let screenSummary = recentScreenSummary()
        let pastChats = pastSessionsSummary()
        let completedTodos = completedTodosSummary()

        var systemPrompt: String
        if mode == .noTodo {
            systemPrompt = """
            You are a warm but direct focus coach. The user is in a pomodoro work session but has no to-do \
            set for today. Help them decide the single most important thing to work on right now, then use the \
            create_todo tool to add it to today's list. Keep responses to 2-3 sentences. Be actionable, not preachy.

            Recent screen activity this pomodoro:
            \(screenSummary)
            """
        } else {
            systemPrompt = """
            You are a warm but direct focus coach. The user is in a pomodoro work session and got distracted. \
            Their current top to-do: "\(currentTopTodo)". \
            Acknowledge their feelings briefly, then suggest a specific, concrete next step to get back to their top to-do. \
            Keep responses to 2-3 sentences. Be actionable, not preachy. \
            If the user says they want to work on something different, use the create_todo tool to add it to their list for today.

            Recent screen activity this pomodoro:
            \(screenSummary)
            """
        }

        systemPrompt += "\n\nCurrent time: \(Self.clockStamp(Date())). Each message below is prefixed with the " +
            "time it was sent, so you can tell how long the user has been lingering and how long since you last spoke."

        let timeLeft = timeRemainingText()
        if !timeLeft.isEmpty {
            systemPrompt += "\n\nTime left in this pomodoro: \(timeLeft). Only reference how much time is " +
                "left if it's accurate — don't claim the session is nearly over when it isn't."
        }

        if !completedTodos.isEmpty {
            systemPrompt += "\n\nTo-dos the user has already completed today (time spent on these was well " +
                "spent — credit it, don't treat it as a distraction):\n\(completedTodos)"
        }

        if !pastChats.isEmpty {
            systemPrompt += "\n\nPrevious coaching conversations this pomodoro:\n\(pastChats)"
        }

        if !endorsedContexts.isEmpty {
            systemPrompt += "\n\nThe user has endorsed these screens as relevant to their task:\n"
            systemPrompt += endorsedContexts.map { "  - \($0)" }.joined(separator: "\n")
        }

        callAPIWithTools(systemPrompt: systemPrompt, messages: conversationHistory, tools: conversationTools) { [weak self] response in
            guard let self else { return }
            self.isRespondingToUser = false
            guard let response else {
                completion("Sorry — I couldn't reach the coach just now. Try again in a moment.")
                return
            }
            self.conversationHistory.append(["role": "assistant", "content": response, "ts": Date()])
            let text = (response as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? (response as? String) ?? ""
            completion(text)
        }
    }

    private func callAPIWithTools(systemPrompt: String, messages: [[String: Any]], tools: [[String: Any]], completion: @escaping (Any?) -> Void) {
        guard let apiKey = readAPIKey(), !apiKey.isEmpty else { completion(nil); return }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // The Anthropic API rejects unknown keys on messages, so drop our internal
        // `ts` before sending; fold the timestamp into the text so the coach still
        // sees when each turn happened.
        let apiMessages: [[String: Any]] = messages.map { msg in
            var out = msg
            out.removeValue(forKey: "ts")
            if let ts = msg["ts"] as? Date, let content = msg["content"] as? String {
                out["content"] = "[\(Self.clockStamp(ts))] \(content)"
            }
            return out
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
            "system": systemPrompt,
            "messages": apiMessages
        ]
        if !tools.isEmpty { body["tools"] = tools }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self, let data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]] else {
                completion(nil)
                return
            }

            let stopReason = json["stop_reason"] as? String
            if stopReason == "tool_use", let toolBlock = content.first(where: { $0["type"] as? String == "tool_use" }) {
                let toolName = toolBlock["name"] as? String
                let toolId = toolBlock["id"] as? String ?? ""
                let input = toolBlock["input"] as? [String: Any] ?? [:]

                // Feed the tool result back and continue the conversation loop.
                let continueWith: (String) -> Void = { [weak self] toolResult in
                    guard let self else { return }
                    var updatedMessages = messages
                    updatedMessages.append(["role": "assistant", "content": content, "ts": Date()])
                    updatedMessages.append(["role": "user", "content": [
                        ["type": "tool_result", "tool_use_id": toolId, "content": toolResult]
                    ], "ts": Date()])
                    self.conversationHistory = updatedMessages
                    self.callAPIWithTools(systemPrompt: systemPrompt, messages: updatedMessages, tools: tools, completion: completion)
                }

                if toolName == "create_todo", let todo = input["content"] as? String {
                    TodoistClient.createTask(content: todo) { ok in
                        continueWith(ok ? "Added \"\(todo)\" to today's list." : "Failed to add the to-do — tell the user to add it manually.")
                    }
                } else {
                    continueWith("done")
                }
            } else {
                completion(content)
            }
        }.resume()
    }

    private func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkFocus()
        }
    }

    private func checkFocus() {
        // Keep checking even while the coach modal is open (so we can send follow-up
        // nudges), but never overlap with an in-flight check or a reply the user is
        // waiting on.
        guard !isChecking, !isRespondingToUser else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"

        if frontApp.bundleIdentifier == "org.metr.ExperienceSampling" { return }

        let windowTitle = getWindowTitle(pid: frontApp.processIdentifier)
        let context = "\(appName)\(windowTitle.map { " — \($0)" } ?? "")"

        recordScreen(context)
        lastDetectedContext = context
        isChecking = true

        TodoistClient.fetchTopTodo { [weak self] result in
            guard let self else { return }
            switch result {
            case .unavailable:
                // No token or the fetch failed — skip this check silently.
                self.isChecking = false
            case .none:
                self.isChecking = false
                self.currentTopTodo = ""
                DispatchQueue.main.async { self.onTopTodoChanged?(nil) }
                self.maybePromptCreateTodo()
            case .todo(let todo):
                self.currentTopTodo = todo.content
                DispatchQueue.main.async { self.onTopTodoChanged?(todo.content) }
                TodoistClient.fetchCompletedTodosToday { [weak self] completed in
                    guard let self else { return }
                    self.recentlyCompletedTodos = completed
                    self.classify(context: context)
                }
            }
        }
    }

    // Builds the classifier user prompt. `isFollowUp` is true when the coach modal
    // is already open, which swaps in follow-up framing and the live conversation.
    private func classifyUserPrompt(context: String, isFollowUp: Bool) -> String {
        let timeLeft = timeRemainingText()
        let timeLine = timeLeft.isEmpty ? "" : "\nTime left in this pomodoro: \(timeLeft)"
        var userPrompt = """
        The user is in a pomodoro. Their top to-do: "\(currentTopTodo)"
        Current time: \(Self.clockStamp(Date()))
        They are currently in: \(context)\(timeLine)

        Recent screen activity this pomodoro:
        \(recentScreenSummary())
        """

        let completedTodos = completedTodosSummary()
        if !completedTodos.isEmpty {
            userPrompt += "\n\nTo-dos the user has already completed today:\n\(completedTodos)"
        }

        let currentChat = currentConversationSummary()
        let pastChats = pastSessionsSummary()
        if isFollowUp && !currentChat.isEmpty {
            userPrompt += "\n\nThe coach modal is already open. The conversation so far:\n\(currentChat)"
        } else if !pastChats.isEmpty {
            userPrompt += "\n\nPrevious coaching conversations this pomodoro:\n\(pastChats)"
        }

        if !endorsedContexts.isEmpty {
            userPrompt += "\n\nThe user has explicitly endorsed these as relevant to their to-do:\n"
            userPrompt += endorsedContexts.map { "  - \($0)" }.joined(separator: "\n")
        }

        userPrompt += """

        \nIs this on-task? Be strict — only on-task if clearly and directly related to the stated to-do.
        Slack, email, social media, news, and casual browsing are off-task even if tangentially related.
        However, if the current screen matches something the user has endorsed as relevant, consider it on-task.

        Important: the recent screen history often includes time the user spent finishing a to-do they have \
        since COMPLETED (see the completed-to-dos list). That time was well spent — it is a success, not a \
        distraction. Judge on-task/off-task only on the CURRENT activity versus the current top to-do, and \
        never scold the user for time or activity that lines up with a to-do they already completed \
        (e.g. don't say "you spent 20 minutes on Slack" when a "catch up on Slack" to-do was just finished). \
        If they just wrapped up a to-do and are momentarily still on that app, that's a natural transition, \
        not a distraction.
        """

        if isFollowUp {
            userPrompt += """


            The coach modal is ALREADY open. Look at what they're doing NOW. You do NOT have to send a \
            message every check — staying quiet is a valid choice. Leave the message empty (and set on_task \
            accordingly) if any of these are true: they've returned to their to-do or something they've \
            endorsed; they seem on-task; or you've already made your point and another nudge would just be \
            nagging. Only if they're still clearly off-task AND a fresh nudge would genuinely help, write a \
            SHORT follow-up (1 sentence) that builds on the conversation above — reference what they're doing \
            now and gently steer them back, and don't repeat a point you've already made (take a different angle).
            """
        } else {
            userPrompt += """


            If off-task, write a conversational opening message (1-2 sentences) that mentions their top to-do, \
            notes what they're looking at, and asks what's going on. Be warm but direct. \
            Use the screen history and past conversations for context — don't repeat yourself if you've already \
            discussed the same distraction.
            If on-task, message can be empty.
            """
        }

        return userPrompt
    }

    private func classify(context: String) {
        let systemPrompt = """
        You are a strict focus coach. Respond with ONLY valid JSON, no other text.
        Format: {"on_task": true/false, "message": "string"}
        """

        let userPrompt = classifyUserPrompt(context: context, isFollowUp: isShowingIntervention)
        let messages: [[String: Any]] = [["role": "user", "content": userPrompt]]

        callClassifyAPI(systemPrompt: systemPrompt, messages: messages) { [weak self] response in
            guard let self else { return }
            self.isChecking = false

            var onTask = true
            var message = ""
            if let response,
               let data = response.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let parsed = json["on_task"] as? Bool {
                onTask = parsed
                message = json["message"] as? String ?? ""
            }

            self.logCheck(context: context, onTask: onTask, message: message)

            guard !onTask else { return }
            guard !message.isEmpty else { return }
            self.mode = .offTask

            if self.isShowingIntervention {
                // The coach modal is already open and the user is still off-task —
                // append a fresh nudge to the live conversation instead of opening
                // a second window. Skip if the user started a reply while this check
                // was in flight, so the follow-up doesn't jump ahead of their answer.
                guard !self.isRespondingToUser else { return }
                self.conversationHistory.append(["role": "assistant", "content": message, "ts": Date()])
                DispatchQueue.main.async { self.onFollowUpMessage?(message) }
            } else {
                self.isShowingIntervention = true
                self.conversationHistory = [["role": "assistant", "content": message, "ts": Date()]]
                DispatchQueue.main.async { self.onOffTaskDetected?(message) }
            }
        }
    }

    // When there's no to-do for today, nudge the user to create one — but no more
    // than once every 5 minutes so it doesn't nag on every check.
    private func maybePromptCreateTodo() {
        guard !isShowingIntervention else { return }
        if let last = lastNoTodoPrompt, Date().timeIntervalSince(last) < 300 { return }
        lastNoTodoPrompt = Date()
        mode = .noTodo
        isShowingIntervention = true
        let message = "You don't have a to-do set for today yet. What's the most important thing you want to get done right now? Tell me and I'll add it to your list."
        conversationHistory = [["role": "assistant", "content": message, "ts": Date()]]
        logCheck(context: lastDetectedContext, onTask: false, message: message)
        DispatchQueue.main.async { self.onOffTaskDetected?(message) }
    }

    private func getWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success else { return nil }
        var titleValue: CFTypeRef?
        // swiftlint:disable:next force_cast - AXUIElementCopyAttributeValue guarantees an AXUIElement here.
        guard AXUIElementCopyAttributeValue(windowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success else { return nil }
        return titleValue as? String
    }

    private func callClassifyAPI(systemPrompt: String, messages: [[String: Any]], completion: @escaping (String?) -> Void) {
        guard let apiKey = readAPIKey(), !apiKey.isEmpty else { completion(nil); return }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
            "system": systemPrompt,
            "messages": messages
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else {
                completion(nil)
                return
            }
            completion(text)
        }.resume()
    }

    private func readAPIKey() -> String? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let keyFile = appSupport.appendingPathComponent("ExperienceSampling/anthropic-api-key.txt")
        return try? String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func logCheck(context: String, onTask: Bool, message: String) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logFile = appSupport.appendingPathComponent("ExperienceSampling/focus-log.jsonl")
        let formatter = ISO8601DateFormatter()
        let entry: [String: Any] = [
            "timestamp": formatter.string(from: Date()),
            "task": currentTopTodo,
            "context": context,
            "on_task": onTask,
            "message": message
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let lineWithNewline = line + "\n"
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(lineWithNewline.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? lineWithNewline.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Meeting Attention Monitor

/// Nudges the user back when they drift away from a live meeting. "In a meeting"
/// is inferred from the mic or camera being active (covers Meet, Zoom, etc.); a
/// drift is lingering on a non-allowlisted app/tab past a threshold. The browser
/// is special-cased because it's where Meet lives *and* where most distractions
/// live: it counts as "on the meeting" only while its focused-window title looks
/// like a meeting tab. The decision is split into the pure `classify`/`step`
/// methods so it can be unit-tested headlessly without timers or live AV state.
final class MeetingAttentionMonitor {
    enum Decision: Equatable {
        case onMeeting    // on the Meet/Zoom tab — fine
        case allowed      // an allowlisted app (notes, to-dos, screen share) — fine
        case distraction  // somewhere else — accrue linger time
    }

    private var timer: Timer?
    private var lingerStart: Date?
    private var isShowingNudge = false
    private var snoozedUntilMeetingEnd = false
    private var avInactiveCount = 0
    private(set) var lastContext = ""
    private var inMeetingContext = false
    private var lastContextRefresh: Date?

    let pollInterval: TimeInterval = 5
    // ~3 polls (15s) of no mic/camera before we treat the meeting as over and
    // lift a snooze. A brief AV blip (e.g. muting) shouldn't reset the snooze.
    let avChecksBeforeMeetingEnd = 3
    // The Meet/Zoom probe (AppleScript / AX) is comparatively expensive, so its
    // result is cached and refreshed at most this often.
    let contextRefreshInterval: TimeInterval = 20

    /// Whether a scheduled calendar event is happening now. Injected by the app
    /// (wired to `CalendarMonitor.isInMeeting`) so the monitor stays decoupled.
    var isInScheduledMeeting: () -> Bool = { false }

    var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "meetingAttentionEnabled") as? Bool) ?? true
    }
    var lingerThreshold: TimeInterval {
        TimeInterval(UserDefaults.standard.integer(forKey: "meetingLingerSeconds").nonZeroOr(25))
    }
    static let defaultAllowlist = "Notion,Todoist,zoom.us,screencaptureui"
    var allowlist: [String] {
        let raw = UserDefaults.standard.string(forKey: "meetingAllowlist")
        let source = (raw?.isEmpty == false) ? raw! : Self.defaultAllowlist
        return source.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var onNudge: (() -> Void)?

    // MARK: Pure decision

    static func classify(appName: String,
                         windowTitle: String?,
                         allowlist: [String],
                         browserNames: [String] = ["Chrome", "Safari", "Arc", "Brave", "Microsoft Edge", "Firefox"],
                         meetingMarkers: [String] = ["Meet", "Google Meet", "Zoom", "Webex"]) -> Decision {
        if allowlist.contains(where: { appName.localizedCaseInsensitiveContains($0) }) {
            return .allowed
        }
        if browserNames.contains(where: { appName.localizedCaseInsensitiveContains($0) }) {
            // Without a readable tab title (Accessibility not granted yet) we
            // can't tell the Meet tab from any other — err toward not nagging.
            guard let title = windowTitle, !title.isEmpty else { return .onMeeting }
            return meetingMarkers.contains(where: { title.localizedCaseInsensitiveContains($0) }) ? .onMeeting : .distraction
        }
        return .distraction
    }

    /// One evaluation step. Mutates linger/snooze state and returns true exactly
    /// when a nudge should fire. Driven by the real timer with live signals;
    /// exposed so headless tests can step it with injected time/signals.
    func step(now: Date, meetingActive: Bool, appName: String, windowTitle: String?) -> Bool {
        guard isEnabled else { return false }

        guard meetingActive else {
            lingerStart = nil
            avInactiveCount += 1
            if avInactiveCount >= avChecksBeforeMeetingEnd {
                snoozedUntilMeetingEnd = false
                avInactiveCount = 0
            }
            return false
        }
        avInactiveCount = 0

        guard !snoozedUntilMeetingEnd, !isShowingNudge else { return false }

        lastContext = windowTitle.map { "\(appName) — \($0)" } ?? appName
        switch Self.classify(appName: appName, windowTitle: windowTitle, allowlist: allowlist) {
        case .onMeeting, .allowed:
            lingerStart = nil
            return false
        case .distraction:
            guard let start = lingerStart else { lingerStart = now; return false }
            guard now.timeIntervalSince(start) >= lingerThreshold else { return false }
            lingerStart = nil
            isShowingNudge = true
            return true
        }
    }

    // MARK: Nudge outcomes (called from the app's nudge window)

    /// User said the drift is intentional — stop nudging until this meeting ends.
    func snoozeForMeeting() { snoozedUntilMeetingEnd = true; isShowingNudge = false; lingerStart = nil }
    /// Nudge dismissed (returned to the meeting, or window closed) — re-arm.
    func dismissNudge() { isShowingNudge = false; lingerStart = nil }

    // MARK: Lifecycle

    func start() {
        guard isEnabled else { return }
        reset()
        requestAccessibilityIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func reset() {
        lingerStart = nil
        isShowingNudge = false
        snoozedUntilMeetingEnd = false
        avInactiveCount = 0
        lastContext = ""
        inMeetingContext = false
        lastContextRefresh = nil
    }

    private func tick() {
        let now = Date()
        let av = CalendarMonitor.isCameraRunning() || CalendarMonitor.isMicRunning()
        // A live mic/camera alone isn't a meeting — Wispr Flow dictation also
        // holds the mic. Require a real meeting context too: a scheduled calendar
        // event, or an open Meet/Zoom/Teams call. The context probe (AppleScript /
        // AX) is comparatively expensive, so `&&` short-circuits it away whenever
        // AV is off, and `meetingContext` caches it while AV is on.
        let meetingActive = av && meetingContext(now: now)

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        if frontApp.bundleIdentifier == "org.metr.ExperienceSampling" { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let title = Self.windowTitle(pid: frontApp.processIdentifier)
        if step(now: now, meetingActive: meetingActive, appName: appName, windowTitle: title) {
            logEvent(context: lastContext)
            DispatchQueue.main.async { [weak self] in self?.onNudge?() }
        }
    }

    /// Cached "are we in a real meeting context" check, refreshed at most every
    /// `contextRefreshInterval`. Only called while AV is active (see `tick`).
    private func meetingContext(now: Date) -> Bool {
        if let last = lastContextRefresh, now.timeIntervalSince(last) < contextRefreshInterval {
            return inMeetingContext
        }
        lastContextRefresh = now
        inMeetingContext = isInScheduledMeeting() || Self.meetingCallOpen()
        return inMeetingContext
    }

    private func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    static func windowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success else { return nil }
        var titleValue: CFTypeRef?
        // swiftlint:disable:next force_cast - AXUIElementCopyAttributeValue guarantees an AXUIElement here.
        guard AXUIElementCopyAttributeValue(windowValue as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success else { return nil }
        return titleValue as? String
    }

    // MARK: Meeting-call detection (no Screen Recording required)

    // URL fragments that mean "a video call is open in this tab". Covers Google
    // Meet, Microsoft Teams (work + personal), and Zoom's web client.
    static let meetingURLMarkers = ["meet.google.com", "teams.microsoft.com", "teams.live.com", "zoom.us/wc", "zoom.us/j"]
    // Chromium-family browsers share one AppleScript dialect for tab URLs.
    static let chromiumBrowsers: [(bundleID: String, appName: String)] = [
        ("com.google.Chrome", "Google Chrome"),
        ("com.brave.Browser", "Brave Browser"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.vivaldi.Vivaldi", "Vivaldi")
    ]
    // Native call apps and the window-title marker that means "in a call".
    static let callApps: [(bundleID: String, titleMarker: String)] = [
        ("us.zoom.xos", "Zoom Meeting")
    ]

    /// Best-effort: is a Google Meet / Teams / Zoom call currently open? Checks
    /// native call apps via the Accessibility API and browser tabs via AppleScript
    /// (one-time Automation permission per browser). All probes fail silently.
    static func meetingCallOpen() -> Bool {
        if callAppInMeeting() { return true }
        if browserHasMeetingTab() { return true }
        return false
    }

    static func callAppInMeeting() -> Bool {
        let running = NSWorkspace.shared.runningApplications
        for app in callApps {
            guard let proc = running.first(where: { $0.bundleIdentifier == app.bundleID }) else { continue }
            let appEl = AXUIElementCreateApplication(proc.processIdentifier)
            var windowsVal: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsVal) == .success,
                  let windows = windowsVal as? [AXUIElement] else { continue }
            for window in windows {
                var titleVal: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleVal) == .success,
                   let title = titleVal as? String,
                   title.localizedCaseInsensitiveContains(app.titleMarker) {
                    return true
                }
            }
        }
        return false
    }

    static func browserHasMeetingTab() -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let condition = meetingURLMarkers
            .map { "(theURL contains \"\($0)\")" }
            .joined(separator: " or ")

        for browser in chromiumBrowsers where running.contains(browser.bundleID) {
            let script = """
            tell application "\(browser.appName)"
                repeat with w in windows
                    repeat with t in tabs of w
                        set theURL to URL of t
                        if \(condition) then return true
                    end repeat
                end repeat
            end tell
            return false
            """
            if runAppleScriptReturnsTrue(script) { return true }
        }

        if running.contains("com.apple.Safari") {
            let script = """
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        set theURL to URL of t
                        if \(condition) then return true
                    end repeat
                end repeat
            end tell
            return false
            """
            if runAppleScriptReturnsTrue(script) { return true }
        }
        return false
    }

    private static func runAppleScriptReturnsTrue(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return false }
        return result.booleanValue
    }

    private func logEvent(context: String) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logFile = appSupport.appendingPathComponent("ExperienceSampling/meeting-attention-log.jsonl")
        let entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "context": context,
            "linger_seconds": Int(lingerThreshold)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let lineWithNewline = line + "\n"
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(lineWithNewline.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? lineWithNewline.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Views

/// Gentle nudge shown when the user drifts away from a live meeting. Two ways
/// out: return to the meeting (re-arms), or declare the drift intentional (mutes
/// nudges for the rest of this meeting — the heads-down-in-notes escape hatch).
struct MeetingNudgeView: View {
    var onBack: () -> Void
    var onSnooze: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Still in a meeting?").font(.title2).fontWeight(.semibold)
            Text("You've drifted away from the meeting for a bit. Head back, or let me know you're away on purpose and I'll stay quiet for the rest of this meeting.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button("I'm here on purpose") { onSnooze() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Back to the meeting") { onBack() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

struct LikertScale: View {
    @Binding var selectedValue: Int?
    var isFocused: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(1...7, id: \.self) { value in
                    Button(action: { selectedValue = value }) {
                        Text("\(value)")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                            .background(selectedValue == value ? Color.accentColor : Color.secondary.opacity(0.2))
                            .foregroundColor(selectedValue == value ? .white : .primary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(value)")), modifiers: [])
                }
            }
            .padding(4)
            .background(isFocused ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            HStack {
                Text("Not at all").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("Very excited").font(.caption).foregroundColor(.secondary)
            }
            if isFocused {
                Text("Press 1-7 to select").font(.caption2).foregroundColor(.secondary)
            }
        }
    }
}

enum IntradayFocus: Hashable {
    case activity
    case scale
    case snooze
    case submit
}

struct IntradayView: View {
    @Binding var isPresented: Bool
    @State private var activity: String = ""
    @State private var excitement: Int?
    @FocusState private var focus: IntradayFocus?
    var onSubmit: (String, Int) -> Void
    var onSnooze: () -> Void

    private var isValid: Bool { !activity.trimmingCharacters(in: .whitespaces).isEmpty && excitement != nil }

    var body: some View {
        VStack(spacing: 20) {
            Text("Quick check-in").font(.title2).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("What are you doing?")
                TextField("Brief description (5 words max)", text: $activity)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .activity)
                    .onChange(of: activity) { _, new in if new.count > 30 { activity = String(new.prefix(30)) } }
                    .onSubmit { focus = .scale }
                Text("\(activity.count)/30 characters").font(.caption).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("How excited are you about this?")
                LikertScale(selectedValue: $excitement, isFocused: focus == .scale)
                    .focusable()
                    .focused($focus, equals: .scale)
            }

            HStack(spacing: 12) {
                Button("Snooze 30 min") { onSnooze(); isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
                    .focused($focus, equals: .snooze)
                Button("Submit") {
                    if isValid, let e = excitement { onSubmit(activity.trimmingCharacters(in: .whitespaces), e); isPresented = false }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isValid)
                .buttonStyle(.borderedProminent)
                .focused($focus, equals: .submit)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            focus = .activity
        }
    }
}

struct HistoryView: View {
    @State private var responses: [Response] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            Text("Response History").font(.headline).padding()
            if responses.isEmpty {
                Text("No responses yet").foregroundColor(.secondary).padding()
            } else {
                List(responses) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(r.type == .startOfDay ? "Start of Day" : "Check-in")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(formatter.string(from: r.timestamp)).font(.caption).foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Excitement: \(r.excitement)/7")
                            if let a = r.activity { Text("- \(a)").foregroundColor(.secondary).lineLimit(1) }
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        .frame(width: 400, height: 300)
        .onAppear { responses = DataStore.shared.fetchRecent() }
    }
}

struct SettingsView: View {
    @AppStorage("workingHoursStart") private var workStart = 9
    @AppStorage("workingHoursEnd") private var workEnd = 17
    @AppStorage("averagePromptsPerDay") private var prompts = 3.0
    @AppStorage("pomodoroWorkDuration") private var workDuration = 25
    @AppStorage("pomodoroShortBreak") private var shortBreak = 5
    @AppStorage("pomodoroLongBreak") private var longBreak = 15
    @AppStorage("pomodoroSnooze") private var snooze = 5
    @AppStorage("pomodoroBreakSnooze") private var breakSnooze = 5
    @AppStorage("focusMonitorEnabled") private var focusEnabled = true
    @AppStorage("focusCheckInterval") private var focusInterval = 30
    @AppStorage("focusModel") private var focusModel = FocusMonitor.defaultModel
    @AppStorage("meetingAttentionEnabled") private var meetingAttentionEnabled = true
    @AppStorage("meetingLingerSeconds") private var meetingLingerSeconds = 25
    @AppStorage("meetingAllowlist") private var meetingAllowlist = MeetingAttentionMonitor.defaultAllowlist

    @State private var selectedTab = 0
    @State private var apiKey: String = ""
    @State private var apiKeySaved = false
    @State private var todoistToken: String = ""
    @State private var todoistTokenSaved = false

    private var apiKeyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ExperienceSampling/anthropic-api-key.txt")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Picker("Work Start", selection: $workStart) {
                    ForEach(5..<13, id: \.self) { Text("\($0):00").tag($0) }
                }
                Picker("Work End", selection: $workEnd) {
                    ForEach(14..<22, id: \.self) { Text("\($0):00").tag($0) }
                }
                Stepper("Prompts per day: \(Int(prompts))", value: $prompts, in: 1...10)
            }
            .tabItem { Label("Sampling", systemImage: "chart.bar.doc.horizontal") }
            .tag(0)

            Form {
                Stepper("Work session: \(workDuration) min", value: $workDuration, in: 1...60)
                Stepper("Short break: \(shortBreak) min", value: $shortBreak, in: 1...30)
                Stepper("Long break: \(longBreak) min", value: $longBreak, in: 5...60)
                Stepper("Snooze: \(snooze) min", value: $snooze, in: 5...120)
                Stepper("Break snooze: \(breakSnooze) min", value: $breakSnooze, in: 1...30)
            }
            .tabItem { Label("Pomodoro", systemImage: "timer") }
            .tag(1)

            Form {
                Toggle("Enable focus monitoring", isOn: $focusEnabled)
                Stepper("Check every \(focusInterval)s", value: $focusInterval, in: 10...120, step: 10)
                TextField("Model", text: $focusModel)
                HStack {
                    SecureField("Anthropic API Key", text: $apiKey)
                        .onSubmit { saveAPIKey() }
                    Button("Save") { saveAPIKey() }
                }
                Text(apiKeySaved ? "Key saved" : (apiKey.isEmpty ? "No API key set" : "Press Save to apply"))
                    .font(.caption).foregroundColor(apiKeySaved ? .green : .secondary)
                HStack {
                    SecureField("Todoist API Token", text: $todoistToken)
                        .onSubmit { saveTodoistToken() }
                    Button("Save") { saveTodoistToken() }
                }
                Text(todoistTokenSaved ? "Token saved" : (todoistToken.isEmpty ? "No Todoist token set" : "Press Save to apply"))
                    .font(.caption).foregroundColor(todoistTokenSaved ? .green : .secondary)
            }
            .tabItem { Label("Focus", systemImage: "eye") }
            .tag(2)

            Form {
                Toggle("Nudge me when I drift during meetings", isOn: $meetingAttentionEnabled)
                Stepper("Nudge after \(meetingLingerSeconds)s away", value: $meetingLingerSeconds, in: 10...120, step: 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meeting-OK apps (comma-separated)").font(.caption).foregroundColor(.secondary)
                    TextField("Notion,Todoist,…", text: $meetingAllowlist)
                }
                Text("""
                In a meeting (mic/camera on), lingering on anything else past the threshold \
                triggers a nudge. The browser counts as the meeting only on a Meet/Zoom tab. \
                Takes effect on next app launch.
                """)
                    .font(.caption).foregroundColor(.secondary)
            }
            .tabItem { Label("Meetings", systemImage: "person.2.wave.2") }
            .tag(3)
        }
        .padding()
        .frame(width: 340, height: 320)
        .onAppear { loadAPIKey(); loadTodoistToken() }
    }

    private func loadAPIKey() {
        apiKey = (try? String(contentsOf: apiKeyFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        apiKeySaved = !apiKey.isEmpty
    }

    private func saveAPIKey() {
        try? apiKey.trimmingCharacters(in: .whitespacesAndNewlines).write(to: apiKeyFileURL, atomically: true, encoding: .utf8)
        apiKeySaved = true
    }

    private func loadTodoistToken() {
        todoistToken = (try? String(contentsOf: TodoistClient.tokenFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        todoistTokenSaved = !todoistToken.isEmpty
    }

    private func saveTodoistToken() {
        try? todoistToken.trimmingCharacters(in: .whitespacesAndNewlines).write(to: TodoistClient.tokenFileURL, atomically: true, encoding: .utf8)
        todoistTokenSaved = true
    }
}

// MARK: - Pomodoro Views

enum CombinedStartFocus: Hashable {
    case scale
    case startPomodoro
    case snooze
}

struct CombinedStartOfDayView: View {
    @State private var excitement: Int?
    @FocusState private var focus: CombinedStartFocus?
    var snoozeDuration: Int
    var onStartPomodoro: (Int) -> Void
    var onSnooze: (Int) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Good morning!").font(.title2).fontWeight(.semibold)
            Text("How excited are you to work today?")
            LikertScale(selectedValue: $excitement, isFocused: focus == .scale)
                .focusable()
                .focused($focus, equals: .scale)
            HStack(spacing: 12) {
                Button("Snooze \(snoozeDuration) min") {
                    if let v = excitement { onSnooze(v) }
                }
                .disabled(excitement == nil)
                .focused($focus, equals: .snooze)
                Button("Start Pomodoro") {
                    if let v = excitement { onStartPomodoro(v) }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(excitement == nil)
                .buttonStyle(.borderedProminent)
                .focused($focus, equals: .startPomodoro)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            focus = .scale
        }
    }
}

enum BreakFocus: Hashable {
    case snooze
    case start
}

struct PomodoroBreakView: View {
    @Binding var isPresented: Bool
    let isLongBreak: Bool
    let breakDuration: Int
    let snoozeDuration: Int
    @FocusState private var focus: BreakFocus?
    var onStartBreak: () -> Void
    var onSnooze: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Pomodoro Complete!").font(.title2).fontWeight(.semibold)
            Text("Great work! Time for a \(isLongBreak ? "long" : "short") break.")
            Text("\(breakDuration) minutes").font(.title).fontWeight(.medium)
            HStack(spacing: 12) {
                Button("Snooze \(snoozeDuration) min") { onSnooze(); isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
                    .focused($focus, equals: .snooze)
                Button("Start break") { onStartBreak(); isPresented = false }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .focused($focus, equals: .start)
            }
        }
        .padding(24)
        .frame(width: 300)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            focus = .start
        }
    }
}

enum NextFocus: Hashable {
    case snooze
    case startNext
}

struct PomodoroNextView: View {
    @Binding var isPresented: Bool
    @FocusState private var focus: NextFocus?
    var snoozeDuration: Int
    var workMinutes: Int?
    var onStartNext: () -> Void
    var onSnooze: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Break's Over!").font(.title2).fontWeight(.semibold)
            Text("Ready for another Pomodoro?")
            if let mins = workMinutes {
                Text("\(mins) min (short session)")
                    .font(.caption).foregroundColor(.orange)
            }
            HStack(spacing: 12) {
                Button("Snooze \(snoozeDuration) min") { onSnooze(); isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
                    .focused($focus, equals: .snooze)
                Button("Start Pomodoro") { onStartNext(); isPresented = false }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .focused($focus, equals: .startNext)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            focus = .startNext
        }
    }
}

/// Informational notice shown when a pomodoro ends into a non-video calendar
/// block (e.g. "Lunch"). Unlike the break/next prompts it offers no break or
/// snooze — it just tells the user what's starting and dismisses.
struct EventNoticeView: View {
    let title: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Time for \(title)").font(.title2).fontWeight(.semibold)
            Button("OK") { onDismiss() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 300)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// Holds the coach conversation so the app can push follow-up nudges into an
// already-open modal (checks keep running while the modal is up). The view
// observes this; the app delegate appends to it.
final class FocusChatModel: ObservableObject {
    @Published var messages: [ChatMessage]
    @Published var isLoading = false

    init(initialMessage: String) {
        messages = [ChatMessage(role: .assistant, text: initialMessage)]
    }

    func appendCoachMessage(_ text: String) {
        messages.append(ChatMessage(role: .assistant, text: text))
    }
}

struct FocusInterventionView: View {
    @Binding var isPresented: Bool
    @ObservedObject var model: FocusChatModel
    var onSendMessage: (String, @escaping (String) -> Void) -> Void
    var onDismiss: () -> Void
    var onEndorse: () -> Void

    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Focus Coach").font(.headline)
                Spacer()
                Button("This is relevant") {
                    onEndorse()
                    isPresented = false
                }
                Button("Back to work") {
                    onDismiss()
                    isPresented = false
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.borderedProminent)
            }
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.messages) { msg in
                            HStack {
                                if msg.role == .user { Spacer(minLength: 60) }
                                Text(msg.text)
                                    .padding(10)
                                    .background(msg.role == .assistant ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.2))
                                    .cornerRadius(12)
                                    .textSelection(.enabled)
                                if msg.role == .assistant { Spacer(minLength: 60) }
                            }
                            .id(msg.id)
                        }
                        if model.isLoading {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Thinking...").foregroundColor(.secondary).font(.caption)
                                Spacer()
                            }
                            .id("loading")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("What's going on?", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }
                    .disabled(model.isLoading)
                Button("Send") { sendMessage() }
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || model.isLoading)
            }
            .padding(12)
        }
        .frame(width: 420, height: 350)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            inputFocused = true
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.messages.append(ChatMessage(role: .user, text: text))
        inputText = ""
        model.isLoading = true
        onSendMessage(text) { response in
            DispatchQueue.main.async {
                model.messages.append(ChatMessage(role: .assistant, text: response))
                model.isLoading = false
            }
        }
    }
}

struct PomodoroHistoryView: View {
    @State private var sessions: [PomodoroSession] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            Text("Pomodoro History").font(.headline).padding()
            if sessions.isEmpty {
                Text("No Pomodoros yet").foregroundColor(.secondary).padding()
            } else {
                List(sessions) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(s.completed ? "Completed" : "Abandoned")
                                .font(.caption)
                                .foregroundColor(s.completed ? .green : .secondary)
                            Spacer()
                            Text(formatter.string(from: s.startTime)).font(.caption).foregroundColor(.secondary)
                        }
                        Text(s.taskDescription).lineLimit(1)
                        if let end = s.endTime {
                            let duration = Int(end.timeIntervalSince(s.startTime) / 60)
                            Text("\(duration) min").font(.caption).foregroundColor(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        .frame(width: 400, height: 300)
        .onAppear { sessions = PomodoroDataStore.shared.fetchRecent() }
    }
}

// MARK: - App Delegate

/// Window delegate that runs `onClose` whenever the prompt window closes, for
/// any reason. `windowWillClose` fires on *every* close — the user clicking the
/// native X button, the SwiftUI view setting `isPresented = false`, and
/// programmatic `close()`. Modals now *stack* rather than replace each other
/// (see `showWindow`/`handleModalClosed`), so a new prompt no longer closes the
/// one beneath it; `onClose` therefore fires only on a genuine dismissal of
/// *this* modal. Callers that only want to act on some closes (e.g. snooze
/// unless the user committed an action) gate inside `onClose`.
///
/// Note: this app is LSUIElement with no standard menu bar, so Cmd+W is not
/// routed to `performClose:` and does not close these windows — only the X
/// button and explicit button actions do.
private final class PromptWindowCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    // Stack of open modal windows. Pushing a new modal leaves the ones beneath
    // alive; closing the top re-surfaces the previous one. Delegates are held in
    // a parallel array because NSWindow.delegate is weak.
    private var modalStack: [NSWindow] = []
    private var modalDelegates: [PromptWindowCloseDelegate] = []
    // Live model for the open focus-coach modal, so follow-up nudges from
    // background checks can be appended to the conversation. Nil when no modal.
    private var focusChatModel: FocusChatModel?
    private let scheduler = PromptScheduler()
    private let wakeDetector = WakeDetector()
    private let pomodoroScheduler = PomodoroScheduler()
    private let focusMonitor = FocusMonitor()
    private let meetingMonitor = MeetingAttentionMonitor()
    private let calendarMonitor = CalendarMonitor()
    private let caffeinator = BreakCaffeinator()
    private var abandonMenuItem: NSMenuItem?
    private var currentTaskMenuItem: NSMenuItem?
    private var takeBreakNowMenuItem: NSMenuItem?
    // The live top Todoist to-do the focus coach is tracking, shown in the menu.
    private var topTodo: String = ""
    private var intradaySnoozeTimer: Timer?
    // Fires the "start next pomodoro" prompt when a meeting/lunch that ended a
    // pomodoro is itself over, so the pomodoro flow resumes after the break.
    private var resumeTimer: Timer?
    private let snoozeDuration: TimeInterval = 5 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        scheduler.onPromptTriggered = { [weak self] in
            guard let self else { return }
            let phase = self.pomodoroScheduler.phase
            if phase == .shortBreak || phase == .longBreak { return }
            self.showIntradayPrompt()
        }
        scheduler.start()

        wakeDetector.onNewPomodoroDay = { [weak self] in
            self?.pomodoroScheduler.resetBreakCycle()
            self?.showPomodoroStartOfDay()
        }
        wakeDetector.shouldSuppressPomodoroPrompt = { [weak self] in
            self?.pomodoroScheduler.phase != .idle
        }

        pomodoroScheduler.onTimerTick = { [weak self] seconds, phase in
            self?.updateMenuBarForPomodoro(seconds: seconds, phase: phase)
        }
        pomodoroScheduler.onWorkSessionEnd = { [weak self] in
            guard let self else { return }
            self.focusMonitor.stop()
            self.topTodo = ""
            // If a calendar block is starting now, don't offer a break: a video
            // meeting passes silently; a non-video block (e.g. "Lunch") shows a
            // notice. Otherwise fall through to the normal break prompt.
            if let event = self.calendarMonitor.currentOrImminentEvent(within: self.meetingBuffer + 2) {
                if (event.meetLink ?? "").isEmpty { self.showEventNotice(title: event.summary) }
                self.pomodoroScheduler.endToIdle()
                self.scheduleResumeAfterEvent(end: event.end)
            } else {
                self.showPomodoroBreak()
            }
        }
        pomodoroScheduler.onBreakStart = { [weak self] in self?.caffeinator.breakStarted() }
        pomodoroScheduler.onBreakEnd = { [weak self] in
            self?.caffeinator.breakEnded()
            self?.showPomodoroNext()
        }
        pomodoroScheduler.onSnoozeEnd = { [weak self] in self?.showPomodoroNext() }
        pomodoroScheduler.onBreakSnoozeEnd = { [weak self] in self?.showPomodoroBreak() }
        pomodoroScheduler.onWorkStart = { [weak self] in
            self?.focusMonitor.start()
            self?.caffeinator.workStarted()
        }

        focusMonitor.onOffTaskDetected = { [weak self] message in
            self?.showFocusIntervention(message: message)
        }
        focusMonitor.onFollowUpMessage = { [weak self] message in
            self?.focusChatModel?.appendCoachMessage(message)
        }
        focusMonitor.workTimeRemaining = { [weak self] in
            guard let self, self.pomodoroScheduler.phase == .work else { return nil }
            return self.pomodoroScheduler.timeRemaining
        }
        focusMonitor.onTopTodoChanged = { [weak self] todo in
            self?.topTodo = todo ?? ""
        }

        meetingMonitor.onNudge = { [weak self] in self?.showMeetingNudge() }
        meetingMonitor.isInScheduledMeeting = { [weak self] in self?.calendarMonitor.isInVideoMeeting() ?? false }
        meetingMonitor.start()

        calendarMonitor.start()
        pomodoroScheduler.restoreState()
        wakeDetector.checkForNewDay()

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "experiencesampling" else { return }

        switch url.host {
        case "start-pomodoro":
            if pomodoroScheduler.phase != .idle {
                pomodoroScheduler.abandon()
                caffeinator.sessionEnded()
            }
            pomodoroScheduler.workDurationOverride = availableWorkMinutes()
            pomodoroScheduler.startWork()
        default:
            break
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.doc.horizontal", accessibilityDescription: "Experience Sampling")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Check in now", action: #selector(showIntradayPrompt), keyEquivalent: "c"))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Start Pomodoro", action: #selector(startPomodoroFromMenu), keyEquivalent: "p"))
        let currentTask = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        currentTask.isEnabled = false
        currentTask.isHidden = true
        currentTaskMenuItem = currentTask
        menu.addItem(currentTask)
        let takeBreakNow = NSMenuItem(title: "Take break now", action: #selector(takeBreakNow), keyEquivalent: "")
        takeBreakNow.isHidden = true
        takeBreakNowMenuItem = takeBreakNow
        menu.addItem(takeBreakNow)
        let abandon = NSMenuItem(title: "Abandon Pomodoro", action: #selector(abandonPomodoro), keyEquivalent: "")
        abandon.isEnabled = false
        abandonMenuItem = abandon
        menu.addItem(abandon)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "View History", action: #selector(showHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Pomodoro History", action: #selector(showPomodoroHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Export Data...", action: #selector(exportData), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())

        let debug = NSMenu()
        debug.addItem(NSMenuItem(title: "Show Pomodoro Start", action: #selector(showPomodoroStartOfDay), keyEquivalent: ""))
        debug.addItem(NSMenuItem(title: "Reset Pomodoro Start", action: #selector(resetPomodoroStartOfDay), keyEquivalent: ""))
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debug
        menu.addItem(debugItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        menu.delegate = self
    }

    private func updateMenuBarForPomodoro(seconds: Int, phase: PomodoroPhase) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let todo = self.topTodo
            switch phase {
            case .idle:
                self.statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.doc.horizontal", accessibilityDescription: "Experience Sampling")
                self.statusItem.button?.title = ""
                self.statusItem.button?.toolTip = nil
                self.abandonMenuItem?.isEnabled = false
                self.currentTaskMenuItem?.isHidden = true
            case .work:
                self.statusItem.button?.image = nil
                let mins = seconds / 60
                let secs = seconds % 60
                self.statusItem.button?.title = String(format: "🍅 %02d:%02d", mins, secs)
                self.statusItem.button?.toolTip = todo.isEmpty ? nil : "Top to-do: \(todo)"
                self.abandonMenuItem?.isEnabled = true
                self.currentTaskMenuItem?.title = "Top to-do: \(todo)"
                self.currentTaskMenuItem?.isHidden = todo.isEmpty
            case .shortBreak, .longBreak:
                self.statusItem.button?.image = nil
                let mins = seconds / 60
                let secs = seconds % 60
                self.statusItem.button?.title = String(format: "☕️ %02d:%02d", mins, secs)
                self.statusItem.button?.toolTip = "On break"
                self.abandonMenuItem?.isEnabled = false
                self.currentTaskMenuItem?.isHidden = true
            }
        }
    }

    /// Push a modal onto the stack. The new window appears on top; any windows
    /// beneath stay alive and re-surface as each modal above them closes.
    private func showWindow<V: View>(_ view: V, allowClose: Bool = true, onClose: (() -> Void)? = nil) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        var styleMask: NSWindow.StyleMask = [.titled]
        if allowClose { styleMask.insert(.closable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: styleMask, backing: .buffered, defer: false)
        window.contentView = hosting
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false
        // The delegate always cleans up the stack, then runs the caller's hook.
        let delegate = PromptWindowCloseDelegate(onClose: { [weak self, weak window] in
            if let window { self?.handleModalClosed(window) }
            onClose?()
        })
        window.delegate = delegate
        modalStack.append(window)
        modalDelegates.append(delegate)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Remove a just-closed modal from the stack and bring the new top forward.
    private func handleModalClosed(_ window: NSWindow) {
        if let i = modalStack.firstIndex(of: window) {
            modalStack.remove(at: i)
            modalDelegates.remove(at: i)
        }
        if let top = modalStack.last {
            top.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Close the top modal. A modal only receives clicks/key shortcuts while it
    /// is the top (windows beneath are ordered back and non-key), so "close the
    /// top" is always "close the one the user is acting on".
    private func closeTopModal() {
        modalStack.last?.close()
    }

    private let minPomodoroDuration = 10
    private let meetingBuffer = 1

    private func deferIfMeeting(action: @escaping () -> Void) {
        if calendarMonitor.isInMeeting() {
            if let meetingEnd = calendarMonitor.currentMeetingEnd() {
                let delay = meetingEnd.timeIntervalSince(Date()) + 30
                Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.deferIfMeeting(action: action)
                }
                return
            }
        }

        if let minsUntil = calendarMonitor.minutesUntilNextMeeting(), minsUntil < minPomodoroDuration + meetingBuffer {
            let delay = Double(minsUntil) * 60 + 30
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.deferIfMeeting(action: action)
            }
            return
        }

        action()
    }

    // Minutes until the configured end of the workday (Settings → working hours).
    // Google Calendar doesn't expose working-hours time ranges via its API, so we
    // use the app's own setting to keep pomodoros from running past quitting time.
    private func minutesUntilEndOfWorkday(from date: Date = Date()) -> Int {
        let cal = Calendar.current
        guard let end = cal.date(bySettingHour: scheduler.workingHoursEnd, minute: 0, second: 0, of: date) else { return .max }
        return Int(end.timeIntervalSince(date) / 60)
    }

    // Whether there's enough of the workday left to be worth auto-starting a
    // pomodoro. The automatic flow (post-break) stops once this is false.
    private func workdayHasRoom() -> Bool {
        minutesUntilEndOfWorkday() >= minPomodoroDuration
    }

    // Work minutes for the next pomodoro, capped so it ends by the next meeting
    // and by the end of the workday — pomodoros never run past quitting time.
    // The workday cap only applies while at least a minPomodoroDuration slice of
    // the day is left; once it's after hours (or under that slice), the cap is
    // skipped so an explicit start still runs a full pomodoro when working late.
    private func availableWorkMinutes() -> Int {
        var cap = pomodoroScheduler.workDuration
        if let minsUntil = calendarMonitor.minutesUntilNextMeeting() {
            cap = min(cap, max(minsUntil - meetingBuffer, minPomodoroDuration))
        }
        let left = minutesUntilEndOfWorkday()
        if left >= minPomodoroDuration { cap = min(cap, left) }
        return cap
    }

    @objc private func showPomodoroStartOfDay() {
        var committed = false
        let view = CombinedStartOfDayView(
            snoozeDuration: pomodoroScheduler.snoozeDuration,
            onStartPomodoro: { [weak self] excitement in
                committed = true
                DataStore.shared.add(Response(timestamp: Date(), type: .startOfDay, excitement: excitement))
                self?.wakeDetector.markPomodoroPrompted()
                self?.closeTopModal()
                self?.startPomodoroNow()
            },
            onSnooze: { [weak self] excitement in
                committed = true
                DataStore.shared.add(Response(timestamp: Date(), type: .startOfDay, excitement: excitement))
                self?.wakeDetector.markPomodoroPrompted()
                self?.pomodoroScheduler.scheduleSnooze()
                self?.closeTopModal()
            }
        )
        // If closed without an answer (e.g. the native X button), don't lose the
        // day's flow: schedule a snooze so the task-input prompt reappears. No
        // response is recorded and the day stays un-marked, so the start-of-day
        // prompt can still show again on the next wake.
        showWindow(view, allowClose: false, onClose: { [weak self] in
            if !committed { self?.pomodoroScheduler.scheduleSnooze() }
        })
    }

    @objc private func startPomodoroFromMenu() {
        startPomodoroNow()
    }

    /// Start a work pomodoro right now, capping the duration if a meeting is
    /// near. Used for explicit user actions (start-of-day "Start Pomodoro"
    /// button, dropdown menu) where the user is already asking to start, so
    /// there's no confirmation modal — work begins immediately. Automatic
    /// triggers (break/snooze end) go through showPomodoroNext instead.
    private func startPomodoroNow() {
        guard pomodoroScheduler.phase == .idle else { return }
        pomodoroScheduler.workDurationOverride = availableWorkMinutes()
        pomodoroScheduler.startWork()
    }

    /// Prompt to start the next pomodoro (or snooze) once a break — or a snooze
    /// — ends. Used for automatic triggers where we don't auto-start work: the
    /// modal waits for the user, so the next pomodoro never ticks down while
    /// they're away from the machine. Defers around meetings, and stops entirely
    /// once the workday is over so it doesn't keep prompting after hours.
    private func showPomodoroNext() {
        guard pomodoroScheduler.phase == .idle else { return }
        guard workdayHasRoom() else { return }
        deferIfMeeting { [weak self] in
            guard let self else { return }
            let workMins = self.availableWorkMinutes()
            let defaultDuration = self.pomodoroScheduler.workDuration
            var presented = true
            var committed = false
            let view = PomodoroNextView(
                isPresented: Binding(get: { presented }, set: { [weak self] v in
                    presented = v; if !v { self?.closeTopModal() }
                }),
                snoozeDuration: self.pomodoroScheduler.snoozeDuration,
                workMinutes: workMins < defaultDuration ? workMins : nil,
                onStartNext: { [weak self] in
                    committed = true
                    self?.pomodoroScheduler.workDurationOverride = workMins
                    self?.pomodoroScheduler.startWork()
                },
                onSnooze: { [weak self] in committed = true; self?.pomodoroScheduler.scheduleSnooze() }
            )
            // Snooze on any close that isn't an explicit Start/Snooze — covers
            // the native X button, so the prompt is never silently lost.
            self.showWindow(view, onClose: { [weak self] in
                if !committed { self?.pomodoroScheduler.scheduleSnooze() }
            })
        }
    }

    private func showPomodoroBreak() {
        let isLong = pomodoroScheduler.isLongBreakDue()
        let duration = isLong ? pomodoroScheduler.longBreakDuration : pomodoroScheduler.shortBreakDuration
        var presented = true
        var committed = false
        let view = PomodoroBreakView(
            isPresented: Binding(get: { presented }, set: { [weak self] v in
                presented = v; if !v { self?.closeTopModal() }
            }),
            isLongBreak: isLong,
            breakDuration: duration,
            snoozeDuration: pomodoroScheduler.breakSnoozeDuration,
            onStartBreak: { [weak self] in committed = true; self?.pomodoroScheduler.startBreak(isLong: isLong) },
            onSnooze: { [weak self] in committed = true; self?.pomodoroScheduler.scheduleBreakSnooze() }
        )
        showWindow(view, onClose: { [weak self] in
            if !committed { self?.pomodoroScheduler.scheduleBreakSnooze() }
        })
    }

    // After a pomodoro ends into a meeting/lunch, prompt to start the next one
    // when that event is over (plus a small buffer). showPomodoroNext already
    // guards on being idle, having workday room left, and defers around any
    // back-to-back meeting — so a stale timer or a late meeting can't misfire.
    private func scheduleResumeAfterEvent(end: Date) {
        resumeTimer?.invalidate()
        let delay = end.timeIntervalSinceNow + 30
        guard delay > 0 else { showPomodoroNext(); return }
        resumeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.showPomodoroNext()
        }
    }

    // Informational notice shown when a pomodoro ends into a non-video calendar
    // block (e.g. "Lunch"). No break is offered; the user just acknowledges it.
    private func showEventNotice(title: String) {
        let view = EventNoticeView(title: title, onDismiss: { [weak self] in self?.closeTopModal() })
        showWindow(view)
    }

    // Start the pending break immediately. Used from the menu after the user has
    // snoozed a break and is now ready — no confirmation modal, since asking to
    // start the break is itself the confirmation.
    @objc private func takeBreakNow() {
        pomodoroScheduler.cancelBreakSnooze()
        pomodoroScheduler.startBreak(isLong: pomodoroScheduler.isLongBreakDue())
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        takeBreakNowMenuItem?.isHidden = !pomodoroScheduler.isBreakSnoozePending
    }

    @objc private func abandonPomodoro() {
        focusMonitor.stop()
        topTodo = ""
        resumeTimer?.invalidate()
        resumeTimer = nil
        pomodoroScheduler.abandon()
        caffeinator.sessionEnded()
    }

    private func showFocusIntervention(message: String) {
        var presented = true
        let model = FocusChatModel(initialMessage: message)
        focusChatModel = model
        let view = FocusInterventionView(
            isPresented: Binding(get: { presented }, set: { [weak self] v in
                presented = v; if !v { self?.closeTopModal() }
            }),
            model: model,
            onSendMessage: { [weak self] text, completion in
                self?.focusMonitor.sendMessage(userText: text, completion: completion)
            },
            onDismiss: { [weak self] in
                self?.focusMonitor.resumeAfterIntervention()
            },
            onEndorse: { [weak self] in
                self?.focusMonitor.endorseCurrentContext()
            }
        )
        // Safety net: if this window is dismissed by any path other than its own
        // buttons (e.g. the native X button), reset the monitor so focus checks
        // resume instead of stalling on a stuck isShowingIntervention flag.
        // Idempotent with the button handlers.
        showWindow(view, allowClose: false, onClose: { [weak self] in
            self?.focusChatModel = nil
            self?.focusMonitor.resumeAfterIntervention()
        })
    }

    private func showMeetingNudge() {
        var committed = false
        let view = MeetingNudgeView(
            onBack: { [weak self] in
                committed = true
                self?.meetingMonitor.dismissNudge()
                self?.closeTopModal()
            },
            onSnooze: { [weak self] in
                committed = true
                self?.meetingMonitor.snoozeForMeeting()
                self?.closeTopModal()
            }
        )
        // Any other close path (the native X button) re-arms the monitor rather
        // than leaving it stuck showing.
        showWindow(view, onClose: { [weak self] in
            if !committed { self?.meetingMonitor.dismissNudge() }
        })
    }

    @objc private func showIntradayPrompt() {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= scheduler.workingHoursStart && hour < scheduler.workingHoursEnd else { return }

        intradaySnoozeTimer?.invalidate()
        var presented = true
        var committed = false
        let snooze: () -> Void = { [weak self] in
            self?.intradaySnoozeTimer = Timer.scheduledTimer(withTimeInterval: self?.snoozeDuration ?? 1800, repeats: false) { _ in
                self?.showIntradayPrompt()
            }
        }
        let view = IntradayView(
            isPresented: Binding(get: { presented }, set: { [weak self] v in
                presented = v; if !v { self?.closeTopModal() }
            }),
            onSubmit: { activity, excitement in
                committed = true
                DataStore.shared.add(Response(timestamp: Date(), type: .intraday, excitement: excitement, activity: activity))
            },
            onSnooze: { committed = true; snooze() }
        )
        showWindow(view, onClose: { if !committed { snooze() } })
    }

    @objc private func showHistory() { showWindow(HistoryView()) }
    @objc private func showPomodoroHistory() { showWindow(PomodoroHistoryView()) }
    @objc private func showSettings() { showWindow(SettingsView()) }
    @objc private func resetPomodoroStartOfDay() { wakeDetector.resetPomodoro() }

    @objc private func exportData() {
        let url = DataStore.shared.exportCSV()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "experience-sampling-export.csv"
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.copyItem(at: url, to: dest)
        }
    }
}

// MARK: - Helpers

extension Int {
    func nonZeroOr(_ d: Int) -> Int { self != 0 ? self : d }
}
extension Double {
    func nonZeroOr(_ d: Double) -> Double { self != 0 ? self : d }
}

// MARK: - Main

// An @main struct rather than bare top-level statements: when this file is
// compiled into the headless test binary (with -DTESTING) alongside
// ExperienceSamplingTests/main.swift, the parser rejects top-level expressions
// in a non-main file even inside an inactive #if branch. A declaration is fine,
// and stripping it under -DTESTING lets the test file own the entry point. The
// normal app build (rebuild-and-restart.sh) compiles this file alone.
#if !TESTING
@main
struct ExperienceSamplingApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
#endif
