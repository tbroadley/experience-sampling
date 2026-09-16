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
    /// Length the session was started with, in minutes. Meeting- and
    /// workday-aware capping can start a pomodoro shorter than the configured
    /// work duration; those short ones don't count towards the daily total.
    /// `nil` on sessions written before this was recorded — treated as full.
    var plannedMinutes: Int?

    /// A session counts towards the daily total only if it ran the full
    /// configured work duration.
    func isFullLength(workDuration: Int) -> Bool {
        guard let plannedMinutes else { return true }
        return plannedMinutes >= workDuration
    }
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

    /// Fill in `plannedMinutes` on the in-flight session when it's missing —
    /// it was started by a build from before the field existed. Without this, a
    /// pomodoro that was capped short and then survived an app upgrade decodes
    /// as `nil` and counts as full length. Only ever fills a gap; a session that
    /// already recorded its length is left alone.
    func backfillLastPlannedMinutes(_ minutes: Int) {
        guard let last = sessions.last, last.plannedMinutes == nil else { return }
        sessions[sessions.count - 1].plannedMinutes = minutes
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

    /// Completed *full-length* pomodoros started today. Short ones (capped by a
    /// meeting or the end of the workday) are deliberately excluded.
    func completedTodayCount(workDuration: Int) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return sessions.filter {
            $0.completed
                && calendar.startOfDay(for: $0.startTime) == today
                && $0.isFullLength(workDuration: workDuration)
        }.count
    }

    func exportCSV() -> URL {
        let formatter = ISO8601DateFormatter()
        var csv = "id,start_time,end_time,task,completed,pomodoro_number,planned_minutes\n"
        for s in sessions.sorted(by: { $0.startTime < $1.startTime }) {
            let task = s.taskDescription.replacingOccurrences(of: "\"", with: "\"\"")
            let endTime = s.endTime.map { formatter.string(from: $0) } ?? ""
            let planned = s.plannedMinutes.map(String.init) ?? ""
            csv += "\(s.id),\(formatter.string(from: s.startTime)),\(endTime),\"\(task)\",\(s.completed),\(s.pomodoroNumber),\(planned)\n"
        }
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("pomodoro-export.csv")
        try? csv.write(to: exportURL, atomically: true, encoding: .utf8)
        return exportURL
    }
}

// MARK: - Prompt Policy

/// When self-report modals are allowed to appear.
///
/// Weekends are quiet by default: the "Good morning — how excited are you to
/// work today?" prompt never fires, and the random intraday check-ins only fire
/// when there's evidence the user is actually working — a running pomodoro, or
/// simply being at the Mac (unlocked, with input in the last few minutes).
/// Without that gate a weekend of scheduled prompts fires into an empty room and
/// stacks up: each unanswered modal re-arms a snooze, so they pile on top of each
/// other by the time the user comes back.
enum PromptPolicy {
    /// Seconds of no keyboard/mouse input after which the user counts as away.
    static let activityWindow: TimeInterval = 5 * 60

    static var weekendQuietMode: Bool {
        (UserDefaults.standard.object(forKey: "weekendQuietMode") as? Bool) ?? true
    }

    /// True when the user is plausibly at the Mac right now.
    static func userIsPresent(idleSeconds: TimeInterval? = nil, screenLocked: Bool? = nil) -> Bool {
        if screenLocked ?? BreakCaffeinator.systemScreenLocked() { return false }
        let idle = idleSeconds ?? CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: CGEventType(rawValue: ~0)!
        )
        return idle < activityWindow
    }

    /// Whether the start-of-day prompt may fire. Weekends get no "how excited are
    /// you to work today?" — the honest answer is "I'm not working today".
    static func allowStartOfDayPrompt(now: Date, quietWeekends: Bool, calendar: Calendar = .current) -> Bool {
        !(quietWeekends && calendar.isDateInWeekend(now))
    }

    /// Whether a random intraday check-in may fire. On a weekend it needs a sign
    /// of actual work: a pomodoro in progress, or the user present at the Mac.
    static func allowIntradayPrompt(
        now: Date, inPomodoro: Bool, userPresent: Bool, quietWeekends: Bool, calendar: Calendar = .current
    ) -> Bool {
        guard quietWeekends, calendar.isDateInWeekend(now) else { return true }
        return inPomodoro || userPresent
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

        // The saved phase duration is the authority on how long this session was
        // meant to run, so use it to backfill a session started before
        // `plannedMinutes` was recorded — before deciding whether it completed.
        if savedPhase == .work { PomodoroDataStore.shared.backfillLastPlannedMinutes(duration / 60) }

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
        // to-do live, so sessions are recorded without a fixed task.
        PomodoroDataStore.shared.add(PomodoroSession(
            startTime: Date(),
            taskDescription: "",
            completed: false,
            pomodoroNumber: pomodoroCount,
            plannedMinutes: effectiveDuration
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
        // ...and never on a weekend, where "how excited are you to work today?"
        // is the wrong question. A pomodoro can still be started from the menu.
        guard PromptPolicy.allowStartOfDayPrompt(
            now: Date(), quietWeekends: PromptPolicy.weekendQuietMode, calendar: calendar
        ) else { return }

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
    private var lastCalendarErrorKind: String?
    private var errorThrottle = CoachErrorThrottle()
    /// Fired (on the main queue) when a calendar read fails in a way the user
    /// needs to know about — throttled per kind, like the coach's own errors.
    var onError: ((CoachError) -> Void)?
    /// Fired (on the main queue) the first time a refresh succeeds after
    /// failures, so the UI can clear its "calendar is broken" indicator.
    var onRecovered: (() -> Void)?
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

            let params: [String: Any] = [
                "calendarId": "primary",
                "timeMin": formatter.string(from: now),
                "timeMax": formatter.string(from: endOfDay),
                "singleEvents": true,
                "orderBy": "startTime",
                "maxResults": "20"
            ]
            guard let encoded = try? JSONSerialization.data(withJSONObject: params),
                  let paramString = String(data: encoded, encoding: .utf8) else { return }

            let json: [String: Any]
            switch CalendarCLI.runGws(["calendar", "events", "list", "--params", paramString]) {
            case .success(let payload):
                json = payload
            case .failure(let error):
                // Never silent. An empty calendar and a broken one look identical
                // from the outside — both stop meeting nudges, meeting-aware
                // pomodoro capping, and Meet-link auto-open — and a missing OAuth
                // scope once killed all three for days without a trace.
                self.reportCalendarFailure(error)
                return
            }
            guard let items = json["items"] as? [[String: Any]] else {
                self.reportCalendarFailure(.tasksUnavailable("calendar reply had no `items` array"))
                return
            }
            self.reportCalendarSuccess()

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

    static func calendarError(from error: CoachError) -> CoachError {
        let detail = error.detail
        if looksLikeMissingScope(detail) { return .calendarScopeMissing(detail) }
        switch error {
        case .calendarAuthRequired: return .calendarAuthRequired(detail)
        default: return .calendarUnavailable(detail)
        }
    }

    /// A missing `calendar` scope comes back as 403 `insufficientPermissions`,
    /// worded a couple of different ways depending on whether gws or the API
    /// surfaced it.
    static func looksLikeMissingScope(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("insufficient authentication scopes")
            || lowered.contains("insufficientpermissions")
            || lowered.contains("insufficient permission")
    }

    /// Logs a calendar read failure once per kind — the refresh timer fires every
    /// 5 minutes, and a sustained outage shouldn't bury the log — and surfaces it
    /// to the UI on the same throttle the coach errors use. Logging alone was the
    /// old behaviour, and it meant a dead calendar scope sat unnoticed in
    /// coach-errors.log for twelve days.
    private func reportCalendarFailure(_ error: CoachError) {
        let mapped = Self.calendarError(from: error)
        // Hops to main because `refresh` runs on a concurrent queue and this
        // state, like `events`, is only ever touched there.
        DispatchQueue.main.async {
            if self.lastCalendarErrorKind != mapped.kind {
                self.lastCalendarErrorKind = mapped.kind
                CoachLog.record(mapped, context: "calendar refresh")
            }
            guard self.errorThrottle.shouldSurface(mapped) else { return }
            self.onError?(mapped)
        }
    }

    private func reportCalendarSuccess() {
        DispatchQueue.main.async {
            guard self.lastCalendarErrorKind != nil || self.errorThrottle.hasRecordedFailures else { return }
            CoachLog.record("calendar recovered — a refresh succeeded after earlier failures")
            self.lastCalendarErrorKind = nil
            self.errorThrottle.reset()
            self.onRecovered?()
        }
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
    // The top to-do that was active when this screen was observed. Lets the coach
    // judge past activity against the to-do that was live THEN, not the current one,
    // so time spent on Slack while "catch up on Slack" was the top to-do doesn't get
    // scolded once the top to-do rolls over to something else.
    let topTodo: String
}

// MARK: - Tasks and Calendar clients

struct TaskItem {
    let id: String
    let content: String
    let dayOrder: Int
}

struct CompletedTaskItem {
    let content: String
    let completedAt: Date
}

enum TopTodo {
    case todo(TaskItem)
    case none  // the task store is readable, but has no qualifying to-do for today
    /// Not configured, or the read failed. Carries the reason so the failure is
    /// loud: a broken task source stops every focus check, and silence there is
    /// indistinguishable from a coach that simply has nothing to say.
    case unavailable(CoachError)
}

enum TaskConfiguration {
    static func value(_ key: String, defaultsKey: String) -> String? {
        let values = [UserDefaults.standard.string(forKey: defaultsKey),
                      ProcessInfo.processInfo.environment[key], dashboardValue(key)]
        return values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    static var s3URI: String? { value("TASKS_S3_URI", defaultsKey: "tasksS3URI") }
    static var region: String? { value("TASKS_AWS_REGION", defaultsKey: "tasksAWSRegion") }

    static func dashboardValue(_ key: String) -> String? {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(NSHomeDirectory())/.config"
        let url = URL(fileURLWithPath: config).appendingPathComponent("status-dashboard/.env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseEnvValue(text, key: key)
    }

    /// Minimal `KEY=value` reader — enough for the one line we need, tolerating
    /// comments, blank lines, `export ` prefixes and quoted values.
    static func parseEnvValue(_ text: String, key: String) -> String? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "="),
                  line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

}

enum CalendarCLI {

    /// Where to look for gws. A GUI app inherits a bare PATH, so absolute paths
    /// are required; the nvm install moves with every Node upgrade, hence the
    /// glob over version directories. Override with `defaults write
    /// org.metr.ExperienceSampling gwsPath /path/to/gws`.
    static func findGws() -> String? {
        if let override = UserDefaults.standard.string(forKey: "gwsPath"), !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        var candidates = ["\(NSHomeDirectory())/.local/bin/gws", "/opt/homebrew/bin/gws", "/usr/local/bin/gws"]
        let nvm = "\(NSHomeDirectory())/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        // Newest version first, compared numerically: a lexical sort ranks "v9"
        // above "v24", which would pin us to an ancient Node after an upgrade.
        candidates += versions
            .sorted { nodeVersionOrder($1).lexicographicallyPrecedes(nodeVersionOrder($0)) }
            .map { "\(nvm)/\($0)/bin/gws" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `"v24.12.0"` → `[24, 12, 0]`, for ordering nvm's version directories.
    static func nodeVersionOrder(_ name: String) -> [Int] {
        name.drop { !$0.isNumber }.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Runs `gws` and parses its stdout as JSON. Every failure is a `CoachError`
    /// rather than a nil, so callers can't quietly treat "broken" as "nothing here".
    static func runGws(_ arguments: [String]) -> Result<[String: Any], CoachError> {
        guard arguments.first == "calendar" else { return .failure(.calendarUnavailable("Only Calendar access is supported.")) }
        guard let gws = findGws() else {
            return .failure(.calendarUnavailable("gws CLI not found; set `defaults write org.metr.ExperienceSampling gwsPath`"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gws)
        process.arguments = arguments
        // gws is a Node script with a `#!/usr/bin/env node` shebang, so finding
        // gws itself isn't enough: `env` has to find `node` too, and a GUI app's
        // PATH doesn't include nvm's bin dir. Put gws's own directory first —
        // for an nvm install that's exactly where its matching node lives — so
        // the interpreter can't come back as `exited 127: env: node: not found`.
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        let gwsDir = (gws as NSString).deletingLastPathComponent
        env["PATH"] = "\(gwsDir):\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return .failure(.calendarUnavailable("gws failed to launch: \(error.localizedDescription)"))
        }

        // Drain before waiting: a full pipe buffer would deadlock the child.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = "gws \(arguments.first ?? "") exited \(process.terminationStatus): \(stderr.prefix(300))"
            return .failure(looksLikeAuthFailure(stderr) ? .calendarAuthRequired(detail) : .calendarUnavailable(detail))
        }
        guard let json = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            return .failure(.calendarUnavailable("gws returned unparseable output"))
        }
        if let apiError = json["error"] {
            // A missing OAuth scope lands here as a 403 `insufficientPermissions`
            // with a zero exit code, so it must be caught from the body, not the
            // exit status. `gws auth login --services ...` re-grants; note that
            // gws keeps a token cache that outlives the new grant, so a stale
            // ~/.config/gws/token_cache.json can keep 403ing after a re-login.
            let text = String(describing: apiError)
            let detail = "gws API error: \(text.prefix(300))"
            return .failure(looksLikeAuthFailure(text) ? .calendarAuthRequired(detail) : .calendarUnavailable(detail))
        }
        return .success(json)
    }

    static let requiredScope = "https://www.googleapis.com/auth/calendar.readonly"

    /// Opens Terminal on the gws re-grant, the same `.command` trick
    /// `HawkAuth.launchInteractiveLogin` uses so no Automation permission is
    /// needed. Deletes the token cache afterwards: it outlives a re-login, so
    /// without this the very next call still 403s with the pre-grant token and
    /// the user reasonably concludes the fix didn't work.
    @discardableResult
    static func launchInteractiveLogin() -> Bool {
        guard let path = findGws() else { return false }
        let cache = "\(NSHomeDirectory())/.config/gws/token_cache.json"
        let script = """
        #!/bin/bash
        echo "Re-authorising read-only Calendar access…"
        PATH="\((path as NSString).deletingLastPathComponent):$PATH" \
        "\(path)" auth login --scopes \(requiredScope) || exit $?
        rm -f "\(cache)"
        echo
        echo "Done — you can close this window. The calendar refreshes within 5 minutes."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gws-auth-login.command")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)) != nil else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    static func looksLikeAuthFailure(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return ["unauthorized", "invalid_grant", "credential", "not authenticated",
                "no token", "login", "401", "403"].contains { lowered.contains($0) }
    }

}

enum TasksClient {
    private enum Column {
        static let id = 0, content = 1, due = 4, order = 6, done = 7, completedAt = 8
    }

    static func storageResult<T>(_ operation: () throws -> T) -> Result<T, CoachError> {
        do { return .success(try operation()) } catch let error as TaskStorageError {
            return .failure(error.coachError)
        } catch { return .failure(.tasksUnavailable("Local task storage I/O failed.")) }
    }

    static func loadRows() -> Result<[[String]], CoachError> {
        storageResult {
            try S3TaskStore.configured().read().document.rows.map { row in
                row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
    }

    // MARK: Reads

    /// Mirrors status-dashboard's `get_tasks_for_date(today)`: not done, with a
    /// due date on or before today (overdue included), lowest `order` wins.
    static func topTodo(rows: [[String]], today: String) -> TaskItem? {
        let candidates: [TaskItem] = rows.compactMap { row in
            let id = row[Column.id]
            guard !id.isEmpty, !isTrue(row[Column.done]) else { return nil }
            let due = String(row[Column.due].prefix(10))
            guard !due.isEmpty, due <= today else { return nil }
            return TaskItem(id: id, content: row[Column.content], dayOrder: Int(row[Column.order]) ?? 0)
        }
        return candidates.min { $0.dayOrder < $1.dayOrder }
    }

    /// Tasks ticked off today, most recent first. A recurring task rolls its due
    /// date forward instead of being marked done, so it never appears here —
    /// same as in status-dashboard.
    static func completedToday(rows: [[String]], today: String) -> [CompletedTaskItem] {
        rows.compactMap { row in
            guard isTrue(row[Column.done]) else { return nil }
            let stamp = row[Column.completedAt]
            guard String(stamp.prefix(10)) == today, let date = parseSheetDate(stamp) else { return nil }
            return CompletedTaskItem(content: row[Column.content], completedAt: date)
        }.sorted { $0.completedAt > $1.completedAt }
    }

    static func fetchTopTodo(completion: @escaping (TopTodo) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            switch loadRows() {
            case .failure(let error):
                completion(.unavailable(error))
            case .success(let rows):
                guard let top = topTodo(rows: rows, today: todayString()) else {
                    completion(.none)
                    return
                }
                completion(.todo(top))
            }
        }
    }

    static func fetchCompletedTodosToday(completion: @escaping ([CompletedTaskItem]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            switch loadRows() {
            case .failure:
                // Best-effort context for the coach; the top-to-do read above has
                // already reported anything that's actually broken.
                completion([])
            case .success(let rows):
                completion(completedToday(rows: rows, today: todayString()))
            }
        }
    }

    // MARK: Writes

    /// Appends a task due today, matching status-dashboard's `create_task`.
    static func newTaskRow(content: String, id: String, today: String) -> [String] {
        [id, content, "", "", today, "", "0", "FALSE", ""]
    }

    static func createTask(content: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let row = newTaskRow(content: content, id: UUID().uuidString, today: todayString())
            let result = storageResult { try S3TaskStore.configured().append(row: row) }
            if case .failure(let error) = result {
                CoachLog.record(error, context: "create to-do")
            }
            completion((try? result.get()) != nil)
        }
    }

    // MARK: Helpers

    static func isTrue(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).uppercased() == "TRUE"
    }

    /// Parses the shared task date/datetime strings: "2026-08-10" or an ISO datetime
    /// with a local offset, which is what status-dashboard writes.
    static func parseSheetDate(_ raw: String) -> Date? {
        if raw.count == 10 { return dayFormatter.date(from: raw) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func todayString() -> String { dayFormatter.string(from: Date()) }
}

// MARK: - Claude via METR's Middleman proxy

/// Everything that can go wrong between the focus coach and Claude, kept as
/// distinct cases for two reasons: the UI can then say something actionable
/// ("log in to Hawk") instead of a shrug, and the retry policy can tell "wait a
/// moment and try again" apart from "this will keep failing until the user does
/// something". The old code collapsed all of these into `completion(nil)`, which
/// made the coach go quiet with no signal at all.
enum CoachError: Error, Equatable {
    /// The hawk CLI isn't installed anywhere we look.
    case hawkMissing(String)
    /// hawk is installed but has no usable token, and refreshing didn't help —
    /// a real browser login is required.
    case notAuthenticated(String)
    /// Middleman rejected a token we had just minted (401/403).
    case tokenRejected(String)
    /// Offline, DNS failure, timeout — worth retrying.
    case networkUnavailable(String)
    /// The configured model isn't one this Middleman key may call. `hawk models`
    /// lists more models than the upstream provider keys are entitled to.
    case modelNotEntitled(String)
    /// Any other non-2xx from Middleman.
    case httpError(status: Int, detail: String)
    /// 2xx, but the body wasn't the shape we expect.
    case badResponse(String)
    /// No proxy base URL configured. Deliberately not defaulted in source — see
    /// `MiddlemanClient.baseURL`.
    case proxyNotConfigured(String)
    /// No task storage configured. Without a top to-do there is nothing to
    /// coach against, so this stops the coach just as dead as a missing token.
    case tasksNotConfigured(String)
    /// The AWS CLI has no usable credentials.
    case tasksAuthRequired(String)
    /// AWS CLI missing, S3 request failed, or the document is invalid.
    case tasksUnavailable(String)
    /// The `gws` CLI has no usable Google credentials, so the calendar can't be
    /// read. Distinct from the tasks cases because it takes out a different set
    /// of features and the advice differs.
    case calendarAuthRequired(String)
    /// gws is authenticated but the grant is missing the `calendar` scope. Its
    /// own case because it is both the most likely calendar failure and the one
    /// with the least guessable fix — `gws auth login` alone re-grants without
    /// calendar, and the token cache survives the re-login.
    case calendarScopeMissing(String)
    /// gws missing, the Calendar call failed, or the reply didn't parse.
    case calendarUnavailable(String)

    /// Stable short name, used as the throttle key and in log lines.
    var kind: String {
        switch self {
        case .hawkMissing: return "hawk-missing"
        case .notAuthenticated: return "not-authenticated"
        case .tokenRejected: return "token-rejected"
        case .networkUnavailable: return "network-unavailable"
        case .modelNotEntitled: return "model-not-entitled"
        case .httpError(let status, _): return "http-\(status)"
        case .badResponse: return "bad-response"
        case .proxyNotConfigured: return "proxy-not-configured"
        case .tasksNotConfigured: return "tasks-not-configured"
        case .tasksAuthRequired: return "tasks-auth-required"
        case .tasksUnavailable: return "tasks-unavailable"
        case .calendarAuthRequired: return "calendar-auth-required"
        case .calendarScopeMissing: return "calendar-scope-missing"
        case .calendarUnavailable: return "calendar-unavailable"
        }
    }

    /// Which button the error modal should offer, if any.
    enum FixAction { case none, hawkSignIn, tasksSettings, gwsSignIn }

    var fixAction: FixAction {
        switch self {
        case .hawkMissing, .notAuthenticated, .tokenRejected: return .hawkSignIn
        case .tasksNotConfigured, .tasksAuthRequired: return .tasksSettings
        case .calendarAuthRequired, .calendarScopeMissing: return .gwsSignIn
        default: return .none
        }
    }

    /// True when the fix is "the user authenticates". These are never retried in
    /// a loop — a bad token retried every 30s just hammers Okta and hides the
    /// problem instead of surfacing it.
    var isAuthProblem: Bool {
        switch self {
        case .hawkMissing, .notAuthenticated, .tokenRejected: return true
        case .tasksNotConfigured, .tasksAuthRequired: return true
        case .calendarAuthRequired, .calendarScopeMissing: return true
        default: return false
        }
    }

    /// True when trying again shortly might just work.
    var isTransient: Bool {
        switch self {
        case .networkUnavailable, .tasksUnavailable, .calendarUnavailable: return true
        case .httpError(let status, _): return status == 408 || status == 429 || status >= 500
        default: return false
        }
    }

    /// Headline for the error modal and the menu-bar status item.
    var title: String {
        switch self {
        case .hawkMissing: return "Focus coach: hawk CLI not found"
        case .notAuthenticated: return "Focus coach: not signed in"
        case .tokenRejected: return "Focus coach: sign-in expired"
        case .networkUnavailable: return "Focus coach: can't reach Middleman"
        case .modelNotEntitled: return "Focus coach: model unavailable"
        case .httpError(let status, _): return "Focus coach: Middleman error \(status)"
        case .badResponse: return "Focus coach: unexpected reply"
        case .proxyNotConfigured: return "Focus coach: proxy not configured"
        case .tasksNotConfigured: return "Focus coach: no task list configured"
        case .tasksAuthRequired: return "Focus coach: AWS sign-in needed"
        case .tasksUnavailable: return "Focus coach: task storage unavailable"
        case .calendarAuthRequired: return "Calendar: Google sign-in needed"
        case .calendarScopeMissing: return "Calendar: permission missing"
        case .calendarUnavailable: return "Calendar: can't read your calendar"
        }
    }

    /// What the user should do about it.
    var advice: String {
        switch self {
        case .hawkMissing:
            return """
            The coach talks to Claude through METR's Middleman proxy and needs the \
            hawk CLI to mint an access token. Install it, or point the app at it with \
            `defaults write org.metr.ExperienceSampling hawkPath /path/to/hawk`.
            """
        case .notAuthenticated, .tokenRejected:
            return "Run `hawk auth login` and complete the browser flow. The coach picks the new token up on its next check."
        case .networkUnavailable:
            return "Middleman is only reachable on the METR network. Check your connection/VPN — the coach keeps retrying."
        case .modelNotEntitled(let model):
            return "The Middleman key isn't entitled to \"\(model)\". Pick a different model in Settings → Focus."
        case .httpError:
            return "Middleman returned an error. The coach will retry; if it persists, check Middleman's status."
        case .badResponse:
            return "Middleman replied with something the coach couldn't parse. See coach-errors.log for the detail."
        case .proxyNotConfigured:
            return """
            No proxy URL is configured. hawk normally supplies it via \
            HAWK_MIDDLEMAN_URL in ~/.config/hawk-cli/env; otherwise set one with \
            `defaults write org.metr.ExperienceSampling middlemanBaseURL <url>`.
            """
        case .tasksNotConfigured:
            return """
            Configure the task object's S3 URI in Settings → Focus, or set \
            TASKS_S3_URI in ~/.config/status-dashboard/.env to share the dashboard's \
            task list. Initialize or import the list explicitly using task-store.
            """
        case .tasksAuthRequired:
            return "Run `aws sso login` in a terminal. The AWS CLI owns task-storage authentication; Google sign-in is only for Calendar."
        case .tasksUnavailable:
            return "Reading or updating the S3 task document failed. Check AWS access and connectivity. Existing data is never replaced by an empty list."
        // The calendar advice all names the three features that are down, because
        // their absence is silent: nothing happening is exactly what a quiet
        // calendar looks like, which is how this went unnoticed for days.
        case .calendarAuthRequired:
            return """
            The gws CLI can't reach Google, so meeting nudges, meeting-aware \
            pomodoro capping and Meet-link auto-open are all off. Re-authorise \
            below, or run `gws auth login --scopes https://www.googleapis.com/auth/calendar.readonly`.
            """
        case .calendarScopeMissing:
            return """
            Google is signed in but the `calendar.readonly` permission is missing. Meeting \
            nudges, meeting-aware pomodoro capping and Meet-link auto-open are off. \
            Re-authorise below to request only Calendar read access and clear \
            the stale access-token cache after a successful sign-in.
            """
        case .calendarUnavailable:
            return """
            Reading your calendar failed, so meeting nudges, meeting-aware \
            pomodoro capping and Meet-link auto-open are off. The app retries \
            every 5 minutes; see coach-errors.log for the detail.
            """
        }
    }

    /// One-line detail for the log. Deliberately carries no token material —
    /// only response bodies and hawk's stderr, never hawk's stdout.
    var detail: String {
        switch self {
        case .hawkMissing(let d), .notAuthenticated(let d), .tokenRejected(let d),
             .networkUnavailable(let d), .modelNotEntitled(let d), .badResponse(let d),
             .proxyNotConfigured(let d), .tasksNotConfigured(let d),
             .tasksAuthRequired(let d), .tasksUnavailable(let d),
             .calendarAuthRequired(let d), .calendarScopeMissing(let d),
             .calendarUnavailable(let d):
            return d
        case .httpError(_, let d):
            return d
        }
    }
}

/// Appends focus-coach diagnostics to `coach-errors.log` alongside the other data
/// files, and mirrors them to the unified log (`log stream --predicate
/// 'senderImagePath CONTAINS "ExperienceSampling"'`). The app had no logging at
/// all before, so an auth failure left no trace anywhere.
enum CoachLog {
    static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ExperienceSampling/coach-errors.log")
    }

    static func record(_ message: String) {
        NSLog("[FocusCoach] %@", message)
        let stamp = ISO8601DateFormatter().string(from: Date())
        // One entry per line, so the file stays greppable even when the detail
        // is a multi-line stderr dump from hawk.
        let flattened = message.replacingOccurrences(of: "\n", with: " ⏎ ")
        let line = "\(stamp) \(flattened)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: fileURL)
        }
    }

    static func record(_ error: CoachError, context: String) {
        record("\(context) failed [\(error.kind)]: \(error.detail)")
    }
}

/// Mints the short-lived Middleman access token by shelling out to the hawk CLI.
///
/// hawk owns the whole OAuth story: the refresh token lives in the login
/// keychain (service `hawk-cli:<clientID>`, which only hawk's own binary has an
/// ACL for), and `hawk auth access-token` silently refreshes when the access
/// token is expiring. So "refresh without user action" is simply "run hawk
/// again", and the only case that needs a human is hawk exiting non-zero —
/// which is exactly the `invalid_grant` / expired-refresh-token case.
enum HawkAuth {
    /// Where to look for hawk. A GUI app inherits a bare PATH
    /// (/usr/bin:/bin:/usr/sbin:/sbin), so the bare name never resolves —
    /// absolute candidates are required.
    static var searchPaths: [String] {
        [
            "\(NSHomeDirectory())/.local/bin/hawk",
            "/opt/homebrew/bin/hawk",
            "/usr/local/bin/hawk",
            "/usr/bin/hawk"
        ]
    }

    /// Escape hatch for a non-standard install:
    /// `defaults write org.metr.ExperienceSampling hawkPath /path/to/hawk`.
    static func executablePath() -> String? {
        let fm = FileManager.default
        if let override = UserDefaults.standard.string(forKey: "hawkPath")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return fm.isExecutableFile(atPath: override) ? override : nil
        }
        return searchPaths.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Ask hawk for a new token this far before the current one actually expires,
    /// so a token never dies mid-request.
    static let expiryMargin: TimeInterval = 120
    /// hawk is a Python CLI and may have to do a network refresh, so it's not
    /// instant — but it must not hang the coach either.
    static let subprocessTimeout: TimeInterval = 30

    private static let lock = NSLock()
    private static var cachedToken: String?
    private static var cachedExpiry: Date?

    /// Drop the cached token so the next call re-runs hawk. Used when Middleman
    /// rejects a token we thought was good.
    static func invalidateCachedToken() {
        lock.lock()
        cachedToken = nil
        cachedExpiry = nil
        lock.unlock()
    }

    /// A usable access token. **Blocking** — it may spawn a subprocess, so call
    /// it from a background queue, never the main thread.
    static func token(forceRefresh: Bool = false) -> Result<String, CoachError> {
        if !forceRefresh, let cached = cachedTokenIfFresh() { return .success(cached) }

        guard let path = executablePath() else {
            return .failure(.hawkMissing("no hawk executable at any of: \(searchPaths.joined(separator: ", "))"))
        }

        guard let run = runHawk(path: path, arguments: ["auth", "access-token"]) else {
            return .failure(.notAuthenticated("`hawk auth access-token` did not finish within \(Int(subprocessTimeout))s"))
        }

        // Only stderr is ever logged or wrapped in an error — stdout is the token.
        guard run.status == 0 else {
            let stderr = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = stderr.isEmpty ? "exit status \(run.status)" : String(stderr.suffix(400))
            return .failure(.notAuthenticated(reason))
        }

        let token = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .failure(.notAuthenticated("`hawk auth access-token` succeeded but printed nothing"))
        }

        lock.lock()
        cachedToken = token
        cachedExpiry = expiry(fromJWT: token)
        lock.unlock()
        return .success(token)
    }

    private static func cachedTokenIfFresh() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let token = cachedToken else { return nil }
        // No parseable expiry means we can't reason about freshness, so don't
        // trust the cache — hawk is cheap enough to re-run.
        guard let expiry = cachedExpiry else { return nil }
        return expiry.timeIntervalSinceNow > expiryMargin ? token : nil
    }

    /// Opens Terminal on `hawk auth login` for the cases a token refresh can't
    /// fix. Writing a `.command` file and handing it to LaunchServices runs it in
    /// a new Terminal window without needing Automation permission, which driving
    /// Terminal via AppleScript would.
    @discardableResult
    static func launchInteractiveLogin() -> Bool {
        guard let path = executablePath() else { return false }
        let script = """
        #!/bin/bash
        echo "Signing in to Hawk for the Experience Sampling focus coach…"
        "\(path)" auth login
        echo
        echo "Done — you can close this window. The coach picks the new token up on its next check."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hawk-auth-login.command")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)) != nil else {
            return false
        }
        invalidateCachedToken()
        return NSWorkspace.shared.open(url)
    }

    /// Reads `exp` out of a JWT payload *without* validating the signature. We
    /// only need to know when to ask hawk for a fresh one; Middleman does the
    /// real verification.
    static func expiry(fromJWT jwt: String) -> Date? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1]).replacingOccurrences(of: "-", with: "+")
                                        .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Runs hawk and captures both streams. Returns nil if it overran the
    /// timeout (the process is terminated in that case).
    private static func runHawk(path: String, arguments: [String]) -> (status: Int32, stdout: String, stderr: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // hawk reads ~/.config/hawk-cli/env itself, so it just needs HOME and a
        // PATH sane enough for its interpreter shebang.
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return (status: -1, stdout: "", stderr: "could not launch \(path): \(error.localizedDescription)")
        }

        // Read both pipes on background queues: hawk's output is small, but a
        // full pipe buffer would deadlock waitUntilExit().
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        for (pipe, sink) in [(outPipe, { outData = $0 }), (errPipe, { errData = $0 })] as [(Pipe, (Data) -> Void)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                sink(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }

        let deadline = DispatchTime.now() + subprocessTimeout
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        _ = group.wait(timeout: deadline)

        if process.terminationReason == .uncaughtSignal { return nil }
        return (status: process.terminationStatus,
                stdout: String(bytes: outData, encoding: .utf8) ?? "",
                stderr: String(bytes: errData, encoding: .utf8) ?? "")
    }
}

/// Anthropic-shaped calls routed through METR's Middleman proxy.
///
/// Middleman re-exposes Anthropic's native Messages API verbatim under
/// `/anthropic`, so request and response bodies are byte-for-byte what
/// api.anthropic.com wanted. The only differences from the old direct path are
/// the host and that `x-api-key` carries a short-lived hawk access token instead
/// of a long-lived Anthropic key on disk.
enum MiddlemanClient {
    /// The proxy host is deliberately NOT hardcoded here. This repo is public and
    /// the hostname isn't, so it comes from configuration at runtime instead:
    ///
    ///   1. `defaults write org.metr.ExperienceSampling middlemanBaseURL <url>`
    ///   2. `HAWK_MIDDLEMAN_URL` in `~/.config/hawk-cli/env`, which hawk already
    ///      maintains — so a working hawk install needs no extra setup here.
    ///
    /// With neither, calls fail as `.proxyNotConfigured` rather than silently
    /// falling back to somewhere that would only reject the hawk token anyway.
    static var baseURL: String? {
        if let override = UserDefaults.standard.string(forKey: "middlemanBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        return hawkEnvValue(for: "HAWK_MIDDLEMAN_URL")
    }

    /// Reads a single `KEY=value` out of hawk's env file. Ignores blank lines and
    /// `#` comments, and strips surrounding quotes.
    static func hawkEnvValue(for key: String, envPath: URL? = nil) -> String? {
        let path = envPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hawk-cli/env")
        guard let contents = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static var messagesURL: URL? {
        guard let baseURL else { return nil }
        return URL(string: "\(baseURL)/anthropic/v1/messages")
    }
    static let anthropicVersion = "2023-06-01"
    static let requestTimeout: TimeInterval = 60

    /// Total tries for a single logical call. Only transient failures consume
    /// them; auth problems bail out immediately.
    static let maxAttempts = 3

    /// Backoff before try `attempt + 1`. Deliberately short — a focus check every
    /// 30s shouldn't have a request still limping along when the next one starts.
    static func backoffDelay(afterAttempt attempt: Int) -> TimeInterval {
        [2.0, 6.0][min(max(attempt, 1), 2) - 1]
    }

    /// Maps a non-2xx Middleman response onto a `CoachError`. Pure, so the
    /// classification is unit-tested rather than only exercised against the live
    /// proxy. `body` is Anthropic's error envelope:
    /// `{"type":"error","error":{"type":"...","message":"..."}}`.
    static func classify(status: Int, body: Data, model: String) -> CoachError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let errorObject = json?["error"] as? [String: Any]
        let errorType = errorObject?["type"] as? String ?? ""
        let message = errorObject?["message"] as? String ?? (String(bytes: body.prefix(400), encoding: .utf8) ?? "")
        let detail = "HTTP \(status) \(errorType.isEmpty ? "" : "\(errorType): ")\(message)"

        switch status {
        case 401, 403:
            return .tokenRejected(detail)
        case 404 where errorType == "not_found_error" && message.contains("model"):
            // `hawk models` lists snapshots the upstream provider key can't
            // actually call; those come back as a 404 naming the model.
            return .modelNotEntitled(model)
        default:
            return .httpError(status: status, detail: detail)
        }
    }

    /// URLSession failures that mean "the network, not the server". These are the
    /// ones worth backing off and retrying rather than shouting about.
    static func isNetworkFailure(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff,
            NSURLErrorDataNotAllowed, NSURLErrorSecureConnectionFailed
        ].contains(error.code)
    }

    /// Serializes token minting (which shells out to hawk) and owns the retry
    /// timers, so nothing here ever runs on the main thread.
    private static let queue = DispatchQueue(label: "org.metr.ExperienceSampling.middleman")

    /// One Messages API round trip, with token refresh and retries folded in.
    /// The success value is the decoded top-level response object.
    ///
    /// `maxTokens` covers thinking *and* text: Sonnet 5 spends 150-400 tokens
    /// thinking before the first text block even on trivial prompts, so a budget
    /// sized for the visible answer alone gets eaten entirely by thinking and the
    /// response comes back with no text block at all. Keep it generously large.
    static func sendMessages(model: String,
                             systemPrompt: String,
                             messages: [[String: Any]],
                             tools: [[String: Any]] = [],
                             maxTokens: Int = 2000,
                             completion: @escaping (Result<[String: Any], CoachError>) -> Void) {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": messages
        ]
        if !tools.isEmpty { body["tools"] = tools }
        queue.async { attempt(1, body: body, model: model, didForceRefresh: false, completion: completion) }
    }

    private static func attempt(_ number: Int,
                                body: [String: Any],
                                model: String,
                                didForceRefresh: Bool,
                                completion: @escaping (Result<[String: Any], CoachError>) -> Void) {
        guard let url = messagesURL else {
            completion(.failure(.proxyNotConfigured(
                "no middlemanBaseURL default and no HAWK_MIDDLEMAN_URL in ~/.config/hawk-cli/env")))
            return
        }
        switch HawkAuth.token(forceRefresh: didForceRefresh) {
        case .failure(let error):
            completion(.failure(error))
        case .success(let token):
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            // Middleman's Anthropic passthrough takes the hawk token in the same
            // header Anthropic uses for its own keys — NOT `Authorization: Bearer`,
            // which is what the /openai/... passthrough wants.
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = requestTimeout

            URLSession.shared.dataTask(with: request) { data, response, error in
                queue.async {
                    let outcome = interpret(data: data, response: response, error: error, model: model)
                    switch outcome {
                    case .success(let json):
                        completion(.success(json))
                    case .failure(let coachError):
                        // A rejected token might just be one we cached a moment too
                        // long. Re-mint once and try again immediately; if the fresh
                        // one is rejected too, it's a real auth failure.
                        if case .tokenRejected = coachError, !didForceRefresh {
                            HawkAuth.invalidateCachedToken()
                            CoachLog.record("token rejected by Middleman; re-minting and retrying once")
                            attempt(number, body: body, model: model, didForceRefresh: true, completion: completion)
                            return
                        }
                        guard coachError.isTransient, number < maxAttempts else {
                            completion(.failure(coachError))
                            return
                        }
                        let delay = backoffDelay(afterAttempt: number)
                        CoachLog.record("attempt \(number) failed [\(coachError.kind)]; retrying in \(Int(delay))s")
                        queue.asyncAfter(deadline: .now() + delay) {
                            attempt(number + 1, body: body, model: model,
                                    didForceRefresh: didForceRefresh, completion: completion)
                        }
                    }
                }
            }.resume()
        }
    }

    private static func interpret(data: Data?, response: URLResponse?, error: Error?, model: String) -> Result<[String: Any], CoachError> {
        if let error {
            let nsError = error as NSError
            let detail = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
            return .failure(isNetworkFailure(nsError) ? .networkUnavailable(detail) : .httpError(status: 0, detail: detail))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(.badResponse("no HTTP response"))
        }
        let data = data ?? Data()
        guard (200..<300).contains(http.statusCode) else {
            return .failure(classify(status: http.statusCode, body: data, model: model))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.badResponse("200 but body was not a JSON object (\(data.count) bytes)"))
        }
        return .success(json)
    }
}

/// Keeps a persistent outage from becoming a modal every 30 seconds: the first
/// failure of a kind is loud, repeats of that same kind stay quiet for
/// `interval`, and any success clears the memory so the next failure is loud
/// again. Pure state so the policy is unit-tested.
struct CoachErrorThrottle {
    static let interval: TimeInterval = 10 * 60

    private var lastSurfaced: [String: Date] = [:]

    mutating func shouldSurface(_ error: CoachError, now: Date = Date()) -> Bool {
        if let last = lastSurfaced[error.kind], now.timeIntervalSince(last) < Self.interval { return false }
        lastSurfaced[error.kind] = now
        return true
    }

    var hasRecordedFailures: Bool { !lastSurfaced.isEmpty }

    mutating func reset() { lastSurfaced.removeAll() }
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

    // The current top to-do from S3, re-fetched on every check.
    private var currentTopTodo: String = ""
    // Today's completed to-dos, re-fetched on every check. Given to the coach so it
    // credits time already spent on finished work instead of scolding for it.
    private var recentlyCompletedTodos: [CompletedTaskItem] = []
    var onOffTaskDetected: ((String) -> Void)?
    // Fired when a check finds the user still off-task while the coach modal is
    // already open, so the coach can append a fresh nudge to the live conversation.
    var onFollowUpMessage: ((String) -> Void)?
    var onTopTodoChanged: ((String?) -> Void)?
    /// Fired (on the main queue) when a call to Claude fails in a way the user
    /// needs to know about. Throttled per error kind by `coachErrorThrottle` so a
    /// sustained outage doesn't stack a modal on every check.
    var onCoachError: ((CoachError) -> Void)?
    /// Fired (on the main queue) the first time a call succeeds after failures,
    /// so the UI can clear its "coach is broken" indicator.
    var onCoachRecovered: (() -> Void)?
    private var coachErrorThrottle = CoachErrorThrottle()
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

    /// Log every coach failure, and surface the ones the user hasn't just been
    /// told about. Always logs — the throttle only gates the UI, never the log.
    private func reportCoachError(_ error: CoachError, context: String) {
        CoachLog.record(error, context: context)
        guard coachErrorThrottle.shouldSurface(error) else { return }
        DispatchQueue.main.async { self.onCoachError?(error) }
    }

    /// A successful call clears the throttle, so the next failure is loud again.
    private func noteCoachSuccess() {
        guard coachErrorThrottle.hasRecordedFailures else { return }
        coachErrorThrottle.reset()
        CoachLog.record("coach recovered — a call succeeded after earlier failures")
        DispatchQueue.main.async { self.onCoachRecovered?() }
    }

    private func recordScreen(_ context: String, topTodo: String) {
        screenHistory.append(ScreenObservation(timestamp: Date(), context: context, topTodo: topTodo))
    }

    private func recentScreenSummary() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        // Collapse consecutive observations that share BOTH the context and the
        // top to-do into a single run. Splitting on the to-do too means a stretch of
        // "Slack" gets broken in half at the moment the top to-do rolled over, which
        // is exactly the transition the coach needs to see.
        var runs: [(context: String, todo: String, from: Date, to: Date)] = []
        for obs in screenHistory {
            if let last = runs.last, last.context == obs.context, last.todo == obs.topTodo {
                runs[runs.count - 1] = (last.context, last.todo, last.from, obs.timestamp)
            } else {
                runs.append((obs.context, obs.topTodo, obs.timestamp, obs.timestamp))
            }
        }

        // Emit a "top to-do:" header whenever the active to-do changes, so the
        // timeline reads as blocks of activity under the to-do that was live then.
        var lines: [String] = []
        var lastTodo: String?
        for run in runs.suffix(15) {
            if run.todo != lastTodo {
                lines.append(run.todo.isEmpty ? "  — top to-do at this point: (none set)"
                                             : "  — top to-do at this point: \"\(run.todo)\"")
                lastTodo = run.todo
            }
            let duration = Int(run.to.timeIntervalSince(run.from))
            let durStr = duration > 0 ? " (\(duration)s)" : ""
            lines.append("      \(formatter.string(from: run.from))\(durStr) — \(run.context)")
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
          "description": "Add a new to-do to the user's task list for today. Use this when the user tells you what they want to work on so it becomes part of their list.",
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

        callAPIWithTools(systemPrompt: systemPrompt, messages: conversationHistory, tools: conversationTools) { [weak self] result in
            guard let self else { return }
            self.isRespondingToUser = false
            let response: Any
            switch result {
            case .failure(let error):
                // Say what actually went wrong rather than a vague shrug — the
                // chat window is the surface the user is already looking at.
                completion("⚠️ \(error.title). \(error.advice)")
                return
            case .success(let value):
                response = value
            }
            self.conversationHistory.append(["role": "assistant", "content": response, "ts": Date()])
            let text = (response as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? (response as? String) ?? ""
            completion(text)
        }
    }

    private func callAPIWithTools(systemPrompt: String, messages: [[String: Any]], tools: [[String: Any]],
                                  completion: @escaping (Result<Any, CoachError>) -> Void) {
        // The Messages API rejects unknown keys on messages, so drop our internal
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

        MiddlemanClient.sendMessages(model: model, systemPrompt: systemPrompt, messages: apiMessages, tools: tools) { [weak self] result in
            guard let self else { return }
            let json: [String: Any]
            switch result {
            case .failure(let error):
                self.reportCoachError(error, context: "coach reply")
                completion(.failure(error))
                return
            case .success(let payload):
                json = payload
            }

            guard let content = json["content"] as? [[String: Any]] else {
                let error = CoachError.badResponse("Messages response had no `content` array")
                self.reportCoachError(error, context: "coach reply")
                completion(.failure(error))
                return
            }
            self.noteCoachSuccess()

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
                    TasksClient.createTask(content: todo) { ok in
                        continueWith(ok ? "Added \"\(todo)\" to today's list." : "Failed to add the to-do — tell the user to add it manually.")
                    }
                } else {
                    continueWith("done")
                }
            } else {
                completion(.success(content))
            }
        }
    }

    private func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    // True when the Mac is at the lock screen or the login window (screen locked, or
    // no user session on the console — e.g. fast-user-switched away). We skip focus
    // checks in this state since the user is away from the machine.
    static func systemScreenLockedOrLoggedOut() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        let locked = (info["CGSSessionScreenIsLocked"] as? Int) == 1
        let onConsole = (info["kCGSSessionOnConsoleKey"] as? Bool) ?? true
        return locked || !onConsole
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
        // Don't coach while the Mac is locked or sitting at the login window — the
        // user has stepped away (bathroom, lunch, etc.). The frontmost "app" would
        // just be loginwindow, which only confuses the coach.
        if Self.systemScreenLockedOrLoggedOut() { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"

        if frontApp.bundleIdentifier == "org.metr.ExperienceSampling" { return }

        let windowTitle = getWindowTitle(pid: frontApp.processIdentifier)
        let context = "\(appName)\(windowTitle.map { " — \($0)" } ?? "")"

        lastDetectedContext = context
        isChecking = true

        TasksClient.fetchTopTodo { [weak self] result in
            guard let self else { return }
            switch result {
            case .unavailable(let error):
                // No token or the fetch failed. Keep the last known to-do so the
                // timeline stays continuous, but say so loudly — a dead task
                // token stops every check, and silence here is indistinguishable
                // from a coach that simply has nothing to say.
                self.recordScreen(context, topTodo: self.currentTopTodo)
                self.isChecking = false
                self.reportCoachError(error, context: "top to-do")
            case .none:
                self.currentTopTodo = ""
                self.recordScreen(context, topTodo: "")
                self.isChecking = false
                DispatchQueue.main.async { self.onTopTodoChanged?(nil) }
                self.maybePromptCreateTodo()
            case .todo(let todo):
                self.currentTopTodo = todo.content
                self.recordScreen(context, topTodo: todo.content)
                DispatchQueue.main.async { self.onTopTodoChanged?(todo.content) }
                TasksClient.fetchCompletedTodosToday { [weak self] completed in
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

        Never off-task — these are instrumental or unavoidable, and flagging them is a false positive. \
        If the current screen is one of these, answer on_task: true with an empty message:
          - Sign-in, SSO, and auth screens: the AWS access portal, AWS/Okta/Google Workspace login and \
            verification pages, MFA prompts, "Verify with ..." pages. These are always a step toward some \
            other task, and the user is often just waiting on a redirect or a push notification.
          - The status dashboard (e.g. "Ghostty — status-dashboard"): that is the user's own to-do list — the \
            same list this to-do came from. Reading or reordering it is never a distraction.
          - Empty transition states: "New Tab", "Untitled", blank or still-loading pages. These last a moment \
            while the user types a URL and carry no signal about what they are doing.
          - Meetings and calls: Google Meet, Zoom, Teams, Slack huddles, and any window whose title marks a \
            live call. The user cannot leave a meeting to work on a to-do, so never tell them to wrap it up.
          - The calendar (e.g. "METR - Calendar - Week of ..."): checking or scheduling is ordinary work.
        Judge the screen the user was on BEFORE one of these, not the screen itself; if that earlier screen was \
        off-task and they are still away from their to-do afterwards, you can pick the thread back up then.

        Important: the screen-activity timeline is annotated with the top to-do that was active at each \
        point ("top to-do at this point: ..."). The top to-do can change during a single pomodoro as the \
        user finishes tasks and rolls onto the next. Judge each block of past activity against the to-do that \
        was active AT THAT TIME, not the current one. Time on Slack while "catch up on Slack" was the top \
        to-do was on-task and well spent — do NOT hold it against the user now that the top to-do has moved \
        on to something else. Only the CURRENT activity should be judged against the CURRENT top to-do. \
        Never say things like "you've been bouncing around Slack and email the whole session" when that time \
        lines up with an earlier top to-do (or a to-do they have since completed — see the completed-to-dos \
        list). If they just wrapped up a to-do and are momentarily still on that app, that's a natural \
        transition, not a distraction.
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
        MiddlemanClient.sendMessages(model: model, systemPrompt: systemPrompt, messages: messages) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.reportCoachError(error, context: "focus classification")
                completion(nil)
            case .success(let json):
                guard let content = json["content"] as? [[String: Any]],
                      let text = content.compactMap({ $0["text"] as? String }).first else {
                    // stop_reason is the tell: `max_tokens` means the budget was
                    // spent on the thinking block before any text was emitted.
                    let stopReason = json["stop_reason"] as? String ?? "nil"
                    let blocks = (json["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String } ?? []
                    self.reportCoachError(
                        .badResponse("classification response had no text block "
                                     + "(stop_reason \(stopReason), blocks [\(blocks.joined(separator: ", "))])"),
                        context: "focus classification")
                    completion(nil)
                    return
                }
                self.noteCoachSuccess()
                completion(text)
            }
        }
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
        VStack(spacing: 22) {
            Text("Zoning out?").font(.system(size: 30, weight: .bold))
            VStack(spacing: 14) {
                NudgeTip(icon: "waveform", tint: .orange, text: "Bad audio or video? Fix it now.")
                NudgeTip(icon: "questionmark.bubble.fill", tint: .blue, text: "Lost the thread? Ask a question.")
                NudgeTip(icon: "rectangle.portrait.and.arrow.right", tint: .purple, text: "Not worth it? Just leave.")
            }
            HStack(spacing: 12) {
                Button("Away on purpose") { onSnooze() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Back to it") { onBack() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 420)
    }
}

/// One high-contrast prompt row in the meeting-drift nudge: a colored icon
/// chip and a short, bold instruction.
private struct NudgeTip: View {
    var icon: String
    var tint: Color
    var text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(tint, in: RoundedRectangle(cornerRadius: 12))
            Text(text)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
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
    @AppStorage("weekendQuietMode") private var weekendQuietMode = true
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
    @AppStorage("tasksS3URI") private var tasksS3URI = ""
    // Result of the last "Check connection" — a real round trip to Middleman, so
    // the user can confirm the coach works without waiting for a focus check.
    @State private var claudeStatus: String = ""
    @State private var claudeStatusOK = false
    @State private var isCheckingClaude = false

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
                Toggle("Quiet weekends", isOn: $weekendQuietMode)
                Text("No start-of-day prompt on Saturday/Sunday, and check-ins only while a pomodoro is running or you're at the Mac.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                // Claude goes through METR's Middleman proxy with a short-lived
                // Hawk token — there's no key to paste, only a sign-in to keep alive.
                HStack {
                    Button(isCheckingClaude ? "Checking…" : "Check Claude connection") { checkClaudeConnection() }
                        .disabled(isCheckingClaude)
                    Button("Sign in to Hawk") { HawkAuth.launchInteractiveLogin() }
                }
                Text(claudeStatus.isEmpty ? "Claude runs through Middleman using your Hawk sign-in." : claudeStatus)
                    .font(.caption)
                    .foregroundColor(claudeStatus.isEmpty ? .secondary : (claudeStatusOK ? .green : .red))
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Tasks S3 URI", text: $tasksS3URI)
                Text(tasksStatus)
                    .font(.caption).foregroundColor(TaskConfiguration.s3URI == nil ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tabItem { Label("Focus", systemImage: "eye") }
            .tag(2)

            Form {
                Toggle("Nudge me when I drift during meetings", isOn: $meetingAttentionEnabled)
                Stepper("Nudge after \(meetingLingerSeconds)s away", value: $meetingLingerSeconds, in: 10...120, step: 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meeting-OK apps (comma-separated)").font(.caption).foregroundColor(.secondary)
                    TextField("Notion,Slack,…", text: $meetingAllowlist)
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
        .onAppear { }
    }

    // A real (tiny) Middleman call with the configured model, so this proves the
    // whole chain — hawk token, proxy, model entitlement — not just one link.
    private func checkClaudeConnection() {
        isCheckingClaude = true
        claudeStatus = ""
        let model = focusModel.trimmingCharacters(in: .whitespacesAndNewlines)
        MiddlemanClient.sendMessages(model: model.isEmpty ? FocusMonitor.defaultModel : model,
                                     systemPrompt: "Reply with the single word OK.",
                                     messages: [["role": "user", "content": "ping"]],
                                     maxTokens: 512) { result in
            DispatchQueue.main.async {
                isCheckingClaude = false
                switch result {
                case .success:
                    claudeStatusOK = true
                    claudeStatus = "Connected to Middleman as \(model.isEmpty ? FocusMonitor.defaultModel : model)."
                case .failure(let error):
                    CoachLog.record(error, context: "settings connection check")
                    claudeStatusOK = false
                    claudeStatus = "\(error.title). \(error.advice)"
                }
            }
        }
    }

    private var tasksStatus: String {
        if !tasksS3URI.isEmpty { return "Using the configured S3 task document. AWS CLI sign-in is required." }
        if TaskConfiguration.s3URI != nil { return "Sharing the S3 task list configured outside the app." }
        return "Set TASKS_S3_URI in ~/.config/status-dashboard/.env, or enter an S3 object URI here."
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
    }
}

/// Confirmation for the coach connection check — the happy-path counterpart to
/// `CoachErrorView`.
struct CoachOKView: View {
    let model: String
    let reply: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.green)
                Text("Focus coach connected").font(.system(size: 20, weight: .bold))
            }
            Text("\(model) via Middleman replied \"\(reply)\".")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK") { onDismiss() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

/// Shown when the focus coach can't reach Claude. The point is that the failure
/// is impossible to miss and says what to do about it — the old behaviour was to
/// go silent, so a dead API key looked exactly like "you're on task".
struct CoachErrorView: View {
    let error: CoachError
    var onSignIn: () -> Void
    var onOpenSettings: () -> Void
    var onGwsSignIn: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.orange)
                Text(error.title).font(.system(size: 20, weight: .bold))
            }
            Text(error.advice)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(error.detail)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer()
                Button("Dismiss") { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                switch error.fixAction {
                case .hawkSignIn:
                    Button("Sign in to Hawk") { onSignIn() }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                case .tasksSettings:
                    Button("Open Settings") { onOpenSettings() }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                case .gwsSignIn:
                    Button("Re-authorise Google") { onGwsSignIn() }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                case .none:
                    EmptyView()
                }
            }
        }
        .padding(24)
        .frame(width: 460)
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
    // Whether each stacked window should steal keyboard focus (activate the app
    // and become key) when it surfaces. Parallel to `modalStack`. Only the
    // start-of-day and random intraday check-ins steal focus; everything else
    // (coach, pomodoro/break prompts, notices) surfaces without grabbing focus.
    private var modalStealFocus: [Bool] = []
    // True while a "Good morning" start-of-day prompt is open. Wake notifications
    // fire twice (didWake + screensDidWake) before the user commits, which would
    // otherwise stack a second prompt on top of the first.
    private var startOfDayPromptOpen = false
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
    // A persistent, non-nagging signal that the coach is broken: the modal is
    // throttled, but this menu row stays until a call succeeds. Clicking it
    // re-opens the full explanation.
    private var coachStatusMenuItem: NSMenuItem?
    private var completedTodayMenuItem: NSMenuItem?
    private var lastCoachError: CoachError?
    // The live top to-do the focus coach is tracking, shown in the menu.
    private var topTodo: String = ""
    private var intradaySnoozeTimer: Timer?
    // Fires the "start next pomodoro" prompt when a meeting/lunch that ended a
    // pomodoro is itself over, so the pomodoro flow resumes after the break.
    private var resumeTimer: Timer?
    private let snoozeDuration: TimeInterval = 5 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMainMenu()

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
        focusMonitor.onCoachError = { [weak self] error in
            self?.showCoachError(error)
        }
        focusMonitor.onCoachRecovered = { [weak self] in
            guard let self, let shown = self.lastCoachError else { return }
            // Don't clear a pinned calendar error: the coach recovering says
            // nothing about whether the calendar is still broken.
            guard !shown.kind.hasPrefix("calendar-") else { return }
            self.lastCoachError = nil
            self.coachStatusMenuItem?.isHidden = true
        }

        meetingMonitor.onNudge = { [weak self] in self?.showMeetingNudge() }
        meetingMonitor.isInScheduledMeeting = { [weak self] in self?.calendarMonitor.isInVideoMeeting() ?? false }
        meetingMonitor.start()

        // The calendar shares the coach's error surface — same modal, same
        // menu-bar row. A dead calendar takes out meeting nudges, pomodoro
        // capping and Meet-link auto-open, none of which announce their absence.
        calendarMonitor.onError = { [weak self] error in
            self?.showCoachError(error)
        }
        calendarMonitor.onRecovered = { [weak self] in
            guard let self, let shown = self.lastCoachError else { return }
            // Only clear if the pinned row is the calendar's own — a live coach
            // error must not be wiped by an unrelated calendar recovery.
            guard shown.kind.hasPrefix("calendar-") else { return }
            self.lastCoachError = nil
            self.coachStatusMenuItem?.isHidden = true
        }
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
        case "test-coach":
            checkCoachConnection()
        default:
            break
        }
    }

    /// End-to-end probe of the coach's path to Claude: mint a Hawk token, call
    /// Middleman with the configured model, and report either way. Reachable from
    /// the Debug menu and as `experiencesampling://test-coach` so the whole chain
    /// can be verified without waiting for a focus check to come round.
    @objc private func checkCoachConnection() {
        let model = UserDefaults.standard.string(forKey: "focusModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOr(FocusMonitor.defaultModel)
            ?? FocusMonitor.defaultModel
        CoachLog.record("connection check starting (model \(model), \(MiddlemanClient.messagesURL?.absoluteString ?? "<no proxy configured>"))")
        // 512 rather than a handful: Sonnet 5 emits a thinking block first, and it
        // routinely runs to a couple hundred tokens even for "ping". Too small a
        // budget gets spent entirely on it, so the probe comes back with no text
        // and looks like a failure when it isn't.
        MiddlemanClient.sendMessages(model: model,
                                     systemPrompt: "Reply with the single word OK.",
                                     messages: [["role": "user", "content": "ping"]],
                                     maxTokens: 512) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let json):
                    let text = (json["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
                    CoachLog.record("connection check OK (model \(model)) — replied \"\(text)\"")
                    self?.lastCoachError = nil
                    self?.coachStatusMenuItem?.isHidden = true
                    self?.showCoachOK(model: model, reply: text)
                case .failure(let error):
                    CoachLog.record(error, context: "connection check")
                    self?.showCoachError(error)
                }
            }
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
        let completedToday = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        completedToday.isEnabled = false
        completedTodayMenuItem = completedToday
        menu.addItem(completedToday)
        let abandon = NSMenuItem(title: "Abandon Pomodoro", action: #selector(abandonPomodoro), keyEquivalent: "")
        abandon.isEnabled = false
        abandonMenuItem = abandon
        menu.addItem(abandon)

        let coachStatus = NSMenuItem(title: "", action: #selector(showLastCoachError), keyEquivalent: "")
        coachStatus.isHidden = true
        coachStatusMenuItem = coachStatus
        menu.addItem(coachStatus)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "View History", action: #selector(showHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Pomodoro History", action: #selector(showPomodoroHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Export Data...", action: #selector(exportData), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())

        let debug = NSMenu()
        debug.addItem(NSMenuItem(title: "Show Pomodoro Start", action: #selector(showPomodoroStartOfDay), keyEquivalent: ""))
        debug.addItem(NSMenuItem(title: "Reset Pomodoro Start", action: #selector(resetPomodoroStartOfDay), keyEquivalent: ""))
        debug.addItem(NSMenuItem(title: "Show Meeting Nudge", action: #selector(debugShowMeetingNudge), keyEquivalent: ""))
        debug.addItem(NSMenuItem(title: "Test Coach Connection", action: #selector(checkCoachConnection), keyEquivalent: ""))
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debug
        menu.addItem(debugItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        menu.delegate = self
    }

    /// Install a standard Edit menu. This is an LSUIElement/accessory app with no
    /// visible menu bar, so the system never sees an Edit menu — and the standard
    /// text-editing shortcuts (Cmd+X/C/V/A) work only via that menu's key
    /// equivalents routing through the first responder. Without it, Cmd+V never
    /// reached our text fields (e.g. the focus coach "What's going on?" box), and
    /// paste-based dictation like Wispr Flow silently dropped its text for the same
    /// reason. The menu bar stays hidden (accessory apps show none); only the key
    /// equivalents matter. Cmd, not Ctrl, is the macOS standard for these.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // The first submenu is treated as the application menu; its title is ignored.
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
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
    private func showWindow<V: View>(_ view: V, allowClose: Bool = true, stealFocus: Bool = false, onClose: (() -> Void)? = nil) {
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
        modalStealFocus.append(stealFocus)
        surface(window, stealFocus: stealFocus)
    }

    // Bring a modal window forward. When `stealFocus` is true it activates the
    // app and becomes key (start-of-day / random check-in); otherwise it floats
    // into view without taking keyboard focus, so the user keeps typing in
    // whatever they were doing until they choose to click the window.
    private func surface(_ window: NSWindow, stealFocus: Bool) {
        if stealFocus {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// Remove a just-closed modal from the stack and bring the new top forward.
    private func handleModalClosed(_ window: NSWindow) {
        if let i = modalStack.firstIndex(of: window) {
            modalStack.remove(at: i)
            modalDelegates.remove(at: i)
            modalStealFocus.remove(at: i)
        }
        if let top = modalStack.last {
            surface(top, stealFocus: modalStealFocus.last ?? false)
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
        // Guard against a second prompt stacking on top of the first: paired wake
        // notifications can call this again before the user commits (which is what
        // sets the "already prompted today" flag).
        guard !startOfDayPromptOpen else { return }
        startOfDayPromptOpen = true
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
        showWindow(view, allowClose: false, stealFocus: true, onClose: { [weak self] in
            self?.startOfDayPromptOpen = false
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

    private func showCoachOK(model: String, reply: String) {
        let view = CoachOKView(model: model, reply: reply, onDismiss: { [weak self] in self?.closeTopModal() })
        showWindow(view)
    }

    /// Surface a coach failure: a modal now (the monitor throttles how often this
    /// is called) plus a menu row that persists until a call succeeds.
    private func showCoachError(_ error: CoachError) {
        lastCoachError = error
        coachStatusMenuItem?.title = "⚠︎ \(error.title)"
        coachStatusMenuItem?.isHidden = false
        presentCoachError(error)
    }

    @objc private func showLastCoachError() {
        guard let error = lastCoachError else { return }
        presentCoachError(error)
    }

    private func presentCoachError(_ error: CoachError) {
        let view = CoachErrorView(
            error: error,
            onSignIn: { [weak self] in
                HawkAuth.launchInteractiveLogin()
                self?.closeTopModal()
            },
            onOpenSettings: { [weak self] in
                self?.closeTopModal()
                self?.showSettings()
            },
            onGwsSignIn: { [weak self] in
                CalendarCLI.launchInteractiveLogin()
                self?.closeTopModal()
            },
            onDismiss: { [weak self] in self?.closeTopModal() }
        )
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
        let count = PomodoroDataStore.shared.completedTodayCount(workDuration: pomodoroScheduler.workDuration)
        completedTodayMenuItem?.title = count == 1
            ? "1 pomodoro completed today"
            : "\(count) pomodoros completed today"
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

    @objc private func debugShowMeetingNudge() { showMeetingNudge() }

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

        // On weekends only ask when something says the user is working. Returning
        // here (rather than snoozing) drops the prompt entirely, so a quiet
        // Saturday doesn't accumulate a stack of modals to answer on Monday.
        guard PromptPolicy.allowIntradayPrompt(
            now: Date(),
            inPomodoro: pomodoroScheduler.phase != .idle,
            userPresent: PromptPolicy.userIsPresent(),
            quietWeekends: PromptPolicy.weekendQuietMode
        ) else { return }

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
        showWindow(view, stealFocus: true, onClose: { if !committed { snooze() } })
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
extension String {
    func nonEmptyOr(_ d: String) -> String { isEmpty ? d : self }
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
