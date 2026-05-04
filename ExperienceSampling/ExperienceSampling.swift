import AppKit
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
            for i in 1..<promptTimes.count {
                if promptTimes[i].timeIntervalSince(promptTimes[i - 1]) < minGap {
                    promptTimes[i] = promptTimes[i - 1].addingTimeInterval(minGap)
                }
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
    @Published var currentTask: String = ""
    @Published var pomodoroCount: Int = 0  // cycles 1-4

    var workDuration: Int { UserDefaults.standard.integer(forKey: "pomodoroWorkDuration").nonZeroOr(25) }
    var shortBreakDuration: Int { UserDefaults.standard.integer(forKey: "pomodoroShortBreak").nonZeroOr(5) }
    var longBreakDuration: Int { UserDefaults.standard.integer(forKey: "pomodoroLongBreak").nonZeroOr(15) }
    var snoozeDuration: Int { UserDefaults.standard.integer(forKey: "pomodoroSnooze").nonZeroOr(5) }
    var breakSnoozeDuration: Int { UserDefaults.standard.integer(forKey: "pomodoroBreakSnooze").nonZeroOr(5) }

    private var displayTimer: Timer?
    private var snoozeTimer: Timer?
    private var breakSnoozeTimer: Timer?

    private let phaseKey = "pomodoroPhase"
    private let phaseStartKey = "pomodoroPhaseStart"
    private let phaseDurationKey = "pommadoroPhaseDuration"
    private let taskKey = "pomodoroTask"
    private let countKey = "pomodoroCount"

    var onTimerTick: ((Int, PomodoroPhase) -> Void)?
    var onWorkSessionEnd: (() -> Void)?
    var onBreakEnd: (() -> Void)?
    var onSnoozeEnd: (() -> Void)?
    var onBreakSnoozeEnd: (() -> Void)?
    var onWorkStart: ((String) -> Void)?

    init() {
        pomodoroCount = UserDefaults.standard.integer(forKey: countKey)
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
            currentTask = UserDefaults.standard.string(forKey: taskKey) ?? ""
            timeRemaining = remaining
            startDisplayTimer()
            if savedPhase == .work { onWorkStart?(currentTask) }
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
        UserDefaults.standard.set(Date(), forKey: phaseStartKey)
        UserDefaults.standard.set(timeRemaining, forKey: phaseDurationKey)
        UserDefaults.standard.set(currentTask, forKey: taskKey)
        UserDefaults.standard.set(pomodoroCount, forKey: countKey)
    }

    private func clearSavedState() {
        UserDefaults.standard.removeObject(forKey: phaseKey)
        UserDefaults.standard.removeObject(forKey: phaseStartKey)
        UserDefaults.standard.removeObject(forKey: phaseDurationKey)
        UserDefaults.standard.removeObject(forKey: taskKey)
    }

    var workDurationOverride: Int?

    func startWork(task: String) {
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        currentTask = task
        pomodoroCount = (pomodoroCount % 4) + 1
        phase = .work
        let effectiveDuration = workDurationOverride ?? workDuration
        workDurationOverride = nil
        timeRemaining = effectiveDuration * 60

        PomodoroDataStore.shared.add(PomodoroSession(
            startTime: Date(),
            taskDescription: task,
            completed: false,
            pomodoroNumber: pomodoroCount
        ))

        saveState()
        startDisplayTimer()
        onWorkStart?(task)
    }

    func startBreak(isLong: Bool) {
        phase = isLong ? .longBreak : .shortBreak
        timeRemaining = (isLong ? longBreakDuration : shortBreakDuration) * 60
        saveState()
        startDisplayTimer()
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
            guard let self else { return }
            self.timeRemaining -= 1
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
    private let refreshInterval: TimeInterval = 5 * 60
    private let meetOpenBuffer: TimeInterval = 60

    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        meetLinkTimers.forEach { $0.invalidate() }
        meetLinkTimers = []
    }

    private var acceptedEvents: [CalendarEvent] { events.filter { !$0.declined } }

    func isInMeeting(at date: Date = Date()) -> Bool {
        acceptedEvents.contains { date >= $0.start && date < $0.end }
    }

    func minutesUntilNextMeeting(from date: Date = Date()) -> Int? {
        let upcoming = acceptedEvents.filter { $0.start > date }.sorted { $0.start < $1.start }
        guard let next = upcoming.first else { return nil }
        return Int(next.start.timeIntervalSince(date) / 60)
    }

    func currentMeetingEnd(at date: Date = Date()) -> Date? {
        acceptedEvents.first { date >= $0.start && date < $0.end }?.end
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
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
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

final class FocusMonitor {
    private var timer: Timer?
    private var isShowingIntervention = false
    private var isChecking = false
    private var conversationHistory: [[String: Any]] = []
    private var pastSessions: [[[String: Any]]] = []
    private var screenHistory: [ScreenObservation] = []

    var checkInterval: TimeInterval { Double(UserDefaults.standard.integer(forKey: "focusCheckInterval").nonZeroOr(30)) }
    var isEnabled: Bool {
        let val = UserDefaults.standard.object(forKey: "focusMonitorEnabled")
        return (val as? Bool) ?? true
    }

    var currentTask: String = ""
    var onOffTaskDetected: ((String, String, String) -> Void)?
    var onUpdateTask: ((String) -> Void)?

    func start(task: String) {
        guard isEnabled else { return }
        currentTask = task
        isShowingIntervention = false
        isChecking = false
        conversationHistory = []
        pastSessions = []
        screenHistory = []
        requestAccessibilityIfNeeded()
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func resumeAfterIntervention() {
        isShowingIntervention = false
        if !conversationHistory.isEmpty {
            pastSessions.append(conversationHistory)
        }
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

    private func pastSessionsSummary() -> String {
        guard !pastSessions.isEmpty else { return "" }
        var parts: [String] = []
        for (i, session) in pastSessions.enumerated() {
            var lines: [String] = []
            for msg in session {
                let role = msg["role"] as? String ?? "?"
                if role == "assistant" {
                    let text: String
                    if let content = msg["content"] as? [[String: Any]] {
                        text = content.compactMap { $0["text"] as? String }.joined()
                    } else if let content = msg["content"] as? String {
                        text = content
                    } else { continue }
                    if !text.isEmpty { lines.append("  Coach: \(text)") }
                } else if role == "user" {
                    if let content = msg["content"] as? String {
                        lines.append("  User: \(content)")
                    }
                }
            }
            if !lines.isEmpty {
                parts.append("Session \(i + 1):\n\(lines.joined(separator: "\n"))")
            }
        }
        return parts.joined(separator: "\n")
    }

    private var conversationTools: [[String: Any]] {
        [["name": "update_pomodoro_goal",
          "description": "Update the user's current pomodoro goal/task description. Use this when the user indicates they're moving on to a different task or want to reframe what they're working on.",
          "input_schema": [
            "type": "object",
            "properties": ["new_goal": ["type": "string", "description": "The new goal/task description"]],
            "required": ["new_goal"]
          ]]]
    }

    func sendMessage(userText: String, completion: @escaping (String) -> Void) {
        conversationHistory.append(["role": "user", "content": userText])

        let screenSummary = recentScreenSummary()
        let pastChats = pastSessionsSummary()

        var systemPrompt = """
        You are a warm but direct focus coach. The user is in a pomodoro work session and got distracted. \
        Their current task: "\(currentTask)". \
        Acknowledge their feelings briefly, then suggest a specific, concrete next step to get back to their task. \
        Keep responses to 2-3 sentences. Be actionable, not preachy. \
        If the user says they're switching to a different task, use the update_pomodoro_goal tool to update their goal.

        Recent screen activity this pomodoro:
        \(screenSummary)
        """

        if !pastChats.isEmpty {
            systemPrompt += "\n\nPrevious coaching conversations this pomodoro:\n\(pastChats)"
        }

        callAPIWithTools(systemPrompt: systemPrompt, messages: conversationHistory, tools: conversationTools) { [weak self] response in
            guard let self, let response else { return }
            self.conversationHistory.append(["role": "assistant", "content": response])
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

        var body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 300,
            "system": systemPrompt,
            "messages": messages
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

                var toolResult = "done"
                if toolName == "update_pomodoro_goal", let newGoal = input["new_goal"] as? String {
                    self.currentTask = newGoal
                    DispatchQueue.main.async { self.onUpdateTask?(newGoal) }
                    toolResult = "Goal updated to: \(newGoal)"
                }

                var updatedMessages = messages
                updatedMessages.append(["role": "assistant", "content": content])
                updatedMessages.append(["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": toolId, "content": toolResult]
                ]])

                self.conversationHistory = updatedMessages
                self.callAPIWithTools(systemPrompt: systemPrompt, messages: updatedMessages, tools: tools, completion: completion)
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
        guard !isShowingIntervention, !isChecking else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"

        if frontApp.bundleIdentifier == "org.metr.ExperienceSampling" { return }

        let windowTitle = getWindowTitle(pid: frontApp.processIdentifier)
        let context = "\(appName)\(windowTitle.map { " — \($0)" } ?? "")"

        recordScreen(context)
        isChecking = true

        let screenSummary = recentScreenSummary()
        let pastChats = pastSessionsSummary()

        let systemPrompt = """
        You are a strict focus coach. Respond with ONLY valid JSON, no other text.
        Format: {"on_task": true/false, "message": "string"}
        """

        var userPrompt = """
        The user is in a pomodoro. Their task: "\(currentTask)"
        They are currently in: \(context)

        Recent screen activity this pomodoro:
        \(screenSummary)
        """

        if !pastChats.isEmpty {
            userPrompt += "\n\nPrevious coaching conversations this pomodoro:\n\(pastChats)"
        }

        userPrompt += """

        \nIs this on-task? Be strict — only on-task if clearly and directly related to the stated task.
        Slack, email, social media, news, and casual browsing are off-task even if tangentially related.

        If off-task, write a conversational opening message (1-2 sentences) that mentions their goal, \
        notes what they're looking at, and asks what's going on. Be warm but direct. \
        Use the screen history and past conversations for context — don't repeat yourself if you've already \
        discussed the same distraction.
        If on-task, message can be empty.
        """

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
            self.isShowingIntervention = true
            self.conversationHistory = [["role": "assistant", "content": message]]

            DispatchQueue.main.async {
                self.onOffTaskDetected?(appName, windowTitle ?? "", message)
            }
        }
    }

    private func getWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success else { return nil }
        var titleValue: CFTypeRef?
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
            "model": "claude-sonnet-4-6",
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
            "task": currentTask,
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

// MARK: - Views

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
    @State private var excitement: Int? = nil
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

    @State private var selectedTab = 0
    @State private var apiKey: String = ""
    @State private var apiKeySaved = false

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
                HStack {
                    SecureField("Anthropic API Key", text: $apiKey)
                        .onSubmit { saveAPIKey() }
                    Button("Save") { saveAPIKey() }
                }
                Text(apiKeySaved ? "Key saved" : (apiKey.isEmpty ? "No API key set" : "Press Save to apply"))
                    .font(.caption).foregroundColor(apiKeySaved ? .green : .secondary)
            }
            .tabItem { Label("Focus", systemImage: "eye") }
            .tag(2)
        }
        .padding()
        .frame(width: 320, height: 220)
        .onAppear { loadAPIKey() }
    }

    private func loadAPIKey() {
        apiKey = (try? String(contentsOf: apiKeyFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        apiKeySaved = !apiKey.isEmpty
    }

    private func saveAPIKey() {
        try? apiKey.trimmingCharacters(in: .whitespacesAndNewlines).write(to: apiKeyFileURL, atomically: true, encoding: .utf8)
        apiKeySaved = true
    }
}

// MARK: - Pomodoro Views

enum CombinedStartFocus: Hashable {
    case scale
    case startPomodoro
    case snooze
}

struct CombinedStartOfDayView: View {
    @State private var excitement: Int? = nil
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

enum TaskInputFocus: Hashable {
    case textField
    case snooze
    case start
}

struct PomodoroTaskInputView: View {
    @Binding var isPresented: Bool
    @State private var task: String = ""
    @FocusState private var focus: TaskInputFocus?
    var snoozeDuration: Int
    var workMinutes: Int?
    var onStart: (String) -> Void
    var onSnooze: () -> Void

    private var isValid: Bool { !task.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 20) {
            Text("Start Pomodoro").font(.title2).fontWeight(.semibold)
            if let mins = workMinutes {
                Text("\(mins) min (meeting coming up)")
                    .font(.caption).foregroundColor(.orange)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("What will you work on?")
                TextField("Task description", text: $task)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .textField)
                    .onSubmit { if isValid { onStart(task.trimmingCharacters(in: .whitespaces)); isPresented = false } }
            }
            HStack(spacing: 12) {
                Button("Snooze \(snoozeDuration) min") { onSnooze(); isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
                    .focused($focus, equals: .snooze)
                Button("Start") {
                    if isValid { onStart(task.trimmingCharacters(in: .whitespaces)); isPresented = false }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isValid)
                .buttonStyle(.borderedProminent)
                .focused($focus, equals: .start)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            focus = .textField
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
    case task
    case snooze
    case startNext
}

struct PomodoroNextView: View {
    @Binding var isPresented: Bool
    @State private var task: String = ""
    @FocusState private var focus: NextFocus?
    var snoozeDuration: Int
    var workMinutes: Int?
    var onStartNext: (String) -> Void
    var onSnooze: () -> Void

    private var isValid: Bool { !task.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 20) {
            Text("Break's Over!").font(.title2).fontWeight(.semibold)
            Text("Ready for another Pomodoro?")
            if let mins = workMinutes {
                Text("\(mins) min (meeting coming up)")
                    .font(.caption).foregroundColor(.orange)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("What will you work on?")
                TextField("Task description", text: $task)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .task)
                    .onSubmit { if isValid { onStartNext(task.trimmingCharacters(in: .whitespaces)); isPresented = false } }
            }
            HStack(spacing: 12) {
                Button("Snooze \(snoozeDuration) min") { onSnooze(); isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
                    .focused($focus, equals: .snooze)
                Button("Start Pomodoro") {
                    if isValid { onStartNext(task.trimmingCharacters(in: .whitespaces)); isPresented = false }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isValid)
                .buttonStyle(.borderedProminent)
                .focused($focus, equals: .startNext)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            focus = .task
        }
    }
}

struct FocusInterventionView: View {
    @Binding var isPresented: Bool
    let initialMessage: String
    let currentTask: String
    var onSendMessage: (String, @escaping (String) -> Void) -> Void
    var onDismiss: () -> Void

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isLoading = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Focus Coach").font(.headline)
                Spacer()
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
                        ForEach(messages) { msg in
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
                        if isLoading {
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
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("What's going on?", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }
                    .disabled(isLoading)
                Button("Send") { sendMessage() }
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
            }
            .padding(12)
        }
        .frame(width: 420, height: 350)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            messages = [ChatMessage(role: .assistant, text: initialMessage)]
            inputFocused = true
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: text))
        inputText = ""
        isLoading = true
        onSendMessage(text) { response in
            DispatchQueue.main.async {
                messages.append(ChatMessage(role: .assistant, text: response))
                isLoading = false
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var promptWindow: NSWindow?
    private let scheduler = PromptScheduler()
    private let wakeDetector = WakeDetector()
    private let pomodoroScheduler = PomodoroScheduler()
    private let focusMonitor = FocusMonitor()
    private let calendarMonitor = CalendarMonitor()
    private var abandonMenuItem: NSMenuItem?
    private var currentTaskMenuItem: NSMenuItem?
    private var takeBreakNowMenuItem: NSMenuItem?
    private var intradaySnoozeTimer: Timer?
    private let snoozeDuration: TimeInterval = 5 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        scheduler.onPromptTriggered = { [weak self] in self?.showIntradayPrompt() }
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
            self?.focusMonitor.stop()
            self?.showPomodoroBreak()
        }
        pomodoroScheduler.onBreakEnd = { [weak self] in self?.showPomodoroNext() }
        pomodoroScheduler.onSnoozeEnd = { [weak self] in self?.showPomodoroTaskInputDeferred() }
        pomodoroScheduler.onBreakSnoozeEnd = { [weak self] in self?.showPomodoroBreak() }
        pomodoroScheduler.onWorkStart = { [weak self] task in
            self?.focusMonitor.start(task: task)
        }

        focusMonitor.onOffTaskDetected = { [weak self] appName, windowTitle, message in
            self?.showFocusIntervention(appName: appName, windowTitle: windowTitle, message: message)
        }
        focusMonitor.onUpdateTask = { [weak self] newTask in
            self?.pomodoroScheduler.currentTask = newTask
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
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let taskItem = components.queryItems?.first(where: { $0.name == "task" }),
               let task = taskItem.value, !task.isEmpty {
                if pomodoroScheduler.phase != .idle {
                    pomodoroScheduler.abandon()
                }
                pomodoroScheduler.workDurationOverride = availableWorkMinutes()
                pomodoroScheduler.startWork(task: task)
            } else {
                showPomodoroTaskInput()
            }
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

        menu.addItem(NSMenuItem(title: "Start Pomodoro", action: #selector(showPomodoroTaskInput), keyEquivalent: "p"))
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
            let task = self.pomodoroScheduler.currentTask
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
                self.statusItem.button?.toolTip = task.isEmpty ? nil : "Goal: \(task)"
                self.abandonMenuItem?.isEnabled = true
                self.currentTaskMenuItem?.title = "Goal: \(task)"
                self.currentTaskMenuItem?.isHidden = task.isEmpty
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

    private func showWindow<V: View>(_ view: V, allowClose: Bool = true) {
        promptWindow?.close()
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
        promptWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    private func availableWorkMinutes() -> Int {
        let defaultDuration = pomodoroScheduler.workDuration
        guard let minsUntil = calendarMonitor.minutesUntilNextMeeting() else { return defaultDuration }
        let capped = minsUntil - meetingBuffer
        return capped < defaultDuration ? max(capped, minPomodoroDuration) : defaultDuration
    }

    @objc private func showPomodoroStartOfDay() {
        let view = CombinedStartOfDayView(
            snoozeDuration: pomodoroScheduler.snoozeDuration,
            onStartPomodoro: { [weak self] excitement in
                DataStore.shared.add(Response(timestamp: Date(), type: .startOfDay, excitement: excitement))
                self?.wakeDetector.markPomodoroPrompted()
                self?.promptWindow?.close()
                self?.showPomodoroTaskInput()
            },
            onSnooze: { [weak self] excitement in
                DataStore.shared.add(Response(timestamp: Date(), type: .startOfDay, excitement: excitement))
                self?.wakeDetector.markPomodoroPrompted()
                self?.pomodoroScheduler.scheduleSnooze()
                self?.promptWindow?.close()
            }
        )
        showWindow(view, allowClose: false)
    }

    @objc private func showPomodoroTaskInput() {
        presentPomodoroTaskInput()
    }

    private func showPomodoroTaskInputDeferred() {
        guard pomodoroScheduler.phase == .idle else { return }
        deferIfMeeting { [weak self] in self?.presentPomodoroTaskInput() }
    }

    private func presentPomodoroTaskInput() {
        guard pomodoroScheduler.phase == .idle else { return }
        let workMins = availableWorkMinutes()
        let defaultDuration = pomodoroScheduler.workDuration
        var presented = true
        let view = PomodoroTaskInputView(
            isPresented: Binding(get: { presented }, set: { [weak self] v in
                presented = v; if !v { self?.promptWindow?.close() }
            }),
            snoozeDuration: pomodoroScheduler.snoozeDuration,
            workMinutes: workMins < defaultDuration ? workMins : nil,
            onStart: { [weak self] task in
                self?.pomodoroScheduler.workDurationOverride = workMins
                self?.pomodoroScheduler.startWork(task: task)
            },
            onSnooze: { [weak self] in
                self?.pomodoroScheduler.scheduleSnooze()
            }
        )
        showWindow(view)
    }

    private func showPomodoroBreak() {
        let isLong = pomodoroScheduler.isLongBreakDue()
        let duration = isLong ? pomodoroScheduler.longBreakDuration : pomodoroScheduler.shortBreakDuration
        var presented = true
        let view = PomodoroBreakView(
            isPresented: Binding(get: { presented }, set: { [weak self] v in
                presented = v; if !v { self?.promptWindow?.close() }
            }),
            isLongBreak: isLong,
            breakDuration: duration,
            snoozeDuration: pomodoroScheduler.breakSnoozeDuration,
            onStartBreak: { [weak self] in self?.pomodoroScheduler.startBreak(isLong: isLong) },
            onSnooze: { [weak self] in self?.pomodoroScheduler.scheduleBreakSnooze() }
        )
        showWindow(view)
    }

    private func showPomodoroNext() {
        deferIfMeeting { [weak self] in
            guard let self else { return }
            let workMins = self.availableWorkMinutes()
            let defaultDuration = self.pomodoroScheduler.workDuration
            var presented = true
            let view = PomodoroNextView(
                isPresented: Binding(get: { presented }, set: { [weak self] v in
                    presented = v; if !v { self?.promptWindow?.close() }
                }),
                snoozeDuration: self.pomodoroScheduler.snoozeDuration,
                workMinutes: workMins < defaultDuration ? workMins : nil,
                onStartNext: { [weak self] task in
                    self?.pomodoroScheduler.workDurationOverride = workMins
                    self?.pomodoroScheduler.startWork(task: task)
                },
                onSnooze: { [weak self] in self?.pomodoroScheduler.scheduleSnooze() }
            )
            self.showWindow(view)
        }
    }

    @objc private func takeBreakNow() {
        pomodoroScheduler.cancelBreakSnooze()
        promptWindow?.close()
        showPomodoroBreak()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        takeBreakNowMenuItem?.isHidden = !pomodoroScheduler.isBreakSnoozePending
    }

    @objc private func abandonPomodoro() {
        focusMonitor.stop()
        pomodoroScheduler.abandon()
    }

    private func showFocusIntervention(appName: String, windowTitle: String, message: String) {
        var presented = true
        let view = FocusInterventionView(
            isPresented: Binding(get: { presented }, set: { [weak self] v in
                presented = v; if !v { self?.promptWindow?.close() }
            }),
            initialMessage: message,
            currentTask: pomodoroScheduler.currentTask,
            onSendMessage: { [weak self] text, completion in
                self?.focusMonitor.sendMessage(userText: text, completion: completion)
            },
            onDismiss: { [weak self] in
                self?.focusMonitor.resumeAfterIntervention()
            }
        )
        showWindow(view, allowClose: false)
    }

    @objc private func showIntradayPrompt() {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= scheduler.workingHoursStart && hour < scheduler.workingHoursEnd else { return }

        intradaySnoozeTimer?.invalidate()
        var presented = true
        let view = IntradayView(
            isPresented: Binding(get: { presented }, set: { [weak self] v in
                presented = v; if !v { self?.promptWindow?.close() }
            }),
            onSubmit: { activity, excitement in
                DataStore.shared.add(Response(timestamp: Date(), type: .intraday, excitement: excitement, activity: activity))
            },
            onSnooze: { [weak self] in
                self?.intradaySnoozeTimer = Timer.scheduledTimer(withTimeInterval: self?.snoozeDuration ?? 1800, repeats: false) { _ in
                    self?.showIntradayPrompt()
                }
            }
        )
        showWindow(view)
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
