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
    private var timer: Timer?
    var onPromptTriggered: (() -> Void)?

    var workingHoursStart: Int { UserDefaults.standard.integer(forKey: "workingHoursStart").nonZeroOr(9) }
    var workingHoursEnd: Int { UserDefaults.standard.integer(forKey: "workingHoursEnd").nonZeroOr(17) }
    var averagePromptsPerDay: Double { UserDefaults.standard.double(forKey: "averagePromptsPerDay").nonZeroOr(3.0) }

    func start() { scheduleNextPrompt() }
    func stop() { timer?.invalidate(); timer = nil }

    func scheduleNextPrompt() {
        timer?.invalidate()

        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)

        guard hour >= workingHoursStart && hour < workingHoursEnd else {
            scheduleWorkingHoursCheck()
            return
        }

        let workingMinutes = Double(workingHoursEnd - workingHoursStart) * 60.0
        let lambda = averagePromptsPerDay / workingMinutes
        let u = Double.random(in: Double.ulpOfOne..<1)
        let intervalMinutes = min(max(-log(u) / lambda, 10), 240)

        timer = Timer.scheduledTimer(withTimeInterval: intervalMinutes * 60, repeats: false) { [weak self] _ in
            self?.onPromptTriggered?()
            self?.scheduleNextPrompt()
        }
    }

    private func scheduleWorkingHoursCheck() {
        let calendar = Calendar.current
        let now = Date()
        var nextStart = calendar.date(bySettingHour: workingHoursStart, minute: 0, second: 0, of: now)!
        if nextStart <= now { nextStart = calendar.date(byAdding: .day, value: 1, to: nextStart)! }

        timer = Timer.scheduledTimer(withTimeInterval: nextStart.timeIntervalSince(now), repeats: false) { [weak self] _ in
            self?.scheduleNextPrompt()
        }
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
    var snoozeDuration: Int { UserDefaults.standard.integer(forKey: "pomodoroSnooze").nonZeroOr(30) }
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

    func startWork(task: String) {
        currentTask = task
        pomodoroCount = (pomodoroCount % 4) + 1
        phase = .work
        timeRemaining = workDuration * 60

        PomodoroDataStore.shared.add(PomodoroSession(
            startTime: Date(),
            taskDescription: task,
            completed: false,
            pomodoroNumber: pomodoroCount
        ))

        saveState()
        startDisplayTimer()
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
    @AppStorage("pomodoroSnooze") private var snooze = 30
    @AppStorage("pomodoroBreakSnooze") private var breakSnooze = 5

    @State private var selectedTab = 0

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
        }
        .padding()
        .frame(width: 320, height: 180)
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
                Button("Snooze 30 min") {
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
    var onStart: (String) -> Void
    var onSnooze: () -> Void

    private var isValid: Bool { !task.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 20) {
            Text("Start Pomodoro").font(.title2).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 8) {
                Text("What will you work on?")
                TextField("Task description", text: $task)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .textField)
                    .onSubmit { if isValid { onStart(task.trimmingCharacters(in: .whitespaces)); isPresented = false } }
            }
            HStack(spacing: 12) {
                Button("Snooze 30 min") { onSnooze(); isPresented = false }
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
    @FocusState private var focus: BreakFocus?
    var onStartBreak: () -> Void
    var onSnooze: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Pomodoro Complete!").font(.title2).fontWeight(.semibold)
            Text("Great work! Time for a \(isLongBreak ? "long" : "short") break.")
            Text("\(breakDuration) minutes").font(.title).fontWeight(.medium)
            HStack(spacing: 12) {
                Button("Snooze 30 min") { onSnooze(); isPresented = false }
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
    var onStartNext: (String) -> Void
    var onSnooze: () -> Void

    private var isValid: Bool { !task.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 20) {
            Text("Break's Over!").font(.title2).fontWeight(.semibold)
            Text("Ready for another Pomodoro?")
            VStack(alignment: .leading, spacing: 8) {
                Text("What will you work on?")
                TextField("Task description", text: $task)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .task)
                    .onSubmit { if isValid { onStartNext(task.trimmingCharacters(in: .whitespaces)); isPresented = false } }
            }
            HStack(spacing: 12) {
                Button("Snooze 30 min") { onSnooze(); isPresented = false }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var promptWindow: NSWindow?
    private let scheduler = PromptScheduler()
    private let wakeDetector = WakeDetector()
    private let pomodoroScheduler = PomodoroScheduler()
    private var abandonMenuItem: NSMenuItem?
    private var currentTaskMenuItem: NSMenuItem?
    private var intradaySnoozeTimer: Timer?
    private let snoozeDuration: TimeInterval = 30 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        scheduler.onPromptTriggered = { [weak self] in self?.showIntradayPrompt() }
        scheduler.start()

        wakeDetector.onNewPomodoroDay = { [weak self] in self?.showPomodoroStartOfDay() }
        wakeDetector.shouldSuppressPomodoroPrompt = { [weak self] in
            self?.pomodoroScheduler.phase != .idle
        }

        pomodoroScheduler.onTimerTick = { [weak self] seconds, phase in
            self?.updateMenuBarForPomodoro(seconds: seconds, phase: phase)
        }
        pomodoroScheduler.onWorkSessionEnd = { [weak self] in self?.showPomodoroBreak() }
        pomodoroScheduler.onBreakEnd = { [weak self] in self?.showPomodoroNext() }
        pomodoroScheduler.onSnoozeEnd = { [weak self] in self?.showPomodoroTaskInput() }
        pomodoroScheduler.onBreakSnoozeEnd = { [weak self] in self?.showPomodoroBreak() }

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

    @objc private func showPomodoroStartOfDay() {
        let view = CombinedStartOfDayView(
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
        var presented = true
        let view = PomodoroTaskInputView(
            isPresented: Binding(get: { presented }, set: { [weak self] v in
                presented = v; if !v { self?.promptWindow?.close() }
            }),
            onStart: { [weak self] task in
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
            onStartBreak: { [weak self] in self?.pomodoroScheduler.startBreak(isLong: isLong) },
            onSnooze: { [weak self] in self?.pomodoroScheduler.scheduleBreakSnooze() }
        )
        showWindow(view)
    }

    private func showPomodoroNext() {
        var presented = true
        let view = PomodoroNextView(
            isPresented: Binding(get: { presented }, set: { [weak self] v in
                presented = v; if !v { self?.promptWindow?.close() }
            }),
            onStartNext: { [weak self] task in self?.pomodoroScheduler.startWork(task: task) },
            onSnooze: { [weak self] in self?.pomodoroScheduler.scheduleSnooze() }
        )
        showWindow(view)
    }

    @objc private func abandonPomodoro() {
        pomodoroScheduler.abandon()
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
