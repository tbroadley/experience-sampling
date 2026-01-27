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
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Response].self, from: data) else {
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

// MARK: - Wake Detector

final class WakeDetector {
    private let lastPromptDateKey = "lastStartOfDayPromptDate"
    var onNewDayDetected: (() -> Void)?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkForNewDay()
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkForNewDay()
        }
        checkForNewDay()
    }

    private func checkForNewDay() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let lastDate = UserDefaults.standard.object(forKey: lastPromptDateKey) as? Date
        let lastDay = lastDate.map { calendar.startOfDay(for: $0) }
        if lastDay != today { onNewDayDetected?() }
    }

    func markTodayAsPrompted() {
        UserDefaults.standard.set(Date(), forKey: lastPromptDateKey)
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: lastPromptDateKey)
    }
}

// MARK: - Views

struct LikertScale: View {
    @Binding var selectedValue: Int?

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
                }
            }
            HStack {
                Text("Not at all").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("Very excited").font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

struct StartOfDayView: View {
    @Binding var isPresented: Bool
    @State private var excitement: Int? = nil
    var onSubmit: (Int) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Good morning!").font(.title2).fontWeight(.semibold)
            Text("How excited are you to start working today?")
            LikertScale(selectedValue: $excitement)
            HStack(spacing: 12) {
                Button("Dismiss") { isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Submit") {
                    if let v = excitement { onSubmit(v); isPresented = false }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(excitement == nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

struct IntradayView: View {
    @Binding var isPresented: Bool
    @State private var activity: String = ""
    @State private var excitement: Int? = nil
    var onSubmit: (String, Int) -> Void

    private var isValid: Bool { !activity.trimmingCharacters(in: .whitespaces).isEmpty && excitement != nil }

    var body: some View {
        VStack(spacing: 20) {
            Text("Quick check-in").font(.title2).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("What are you doing?")
                TextField("Brief description (5 words max)", text: $activity)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: activity) { _, new in if new.count > 30 { activity = String(new.prefix(30)) } }
                Text("\(activity.count)/30 characters").font(.caption).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("How excited are you about this?")
                LikertScale(selectedValue: $excitement)
            }

            HStack(spacing: 12) {
                Button("Dismiss") { isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Submit") {
                    if isValid, let e = excitement { onSubmit(activity.trimmingCharacters(in: .whitespaces), e); isPresented = false }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!isValid)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
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

    var body: some View {
        Form {
            Picker("Work Start", selection: $workStart) {
                ForEach(5..<13, id: \.self) { Text("\($0):00").tag($0) }
            }
            Picker("Work End", selection: $workEnd) {
                ForEach(14..<22, id: \.self) { Text("\($0):00").tag($0) }
            }
            Stepper("Prompts per day: \(Int(prompts))", value: $prompts, in: 1...10)
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var promptWindow: NSWindow?
    private let scheduler = PromptScheduler()
    private let wakeDetector = WakeDetector()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        scheduler.onPromptTriggered = { [weak self] in self?.showIntradayPrompt() }
        scheduler.start()

        wakeDetector.onNewDayDetected = { [weak self] in self?.showStartOfDayPrompt() }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.doc.horizontal", accessibilityDescription: "Experience Sampling")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Check in now", action: #selector(showIntradayPrompt), keyEquivalent: "c"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "View History", action: #selector(showHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Export Data...", action: #selector(exportData), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())

        let debug = NSMenu()
        debug.addItem(NSMenuItem(title: "Show Start of Day", action: #selector(showStartOfDayPrompt), keyEquivalent: ""))
        debug.addItem(NSMenuItem(title: "Reset Start of Day", action: #selector(resetStartOfDay), keyEquivalent: ""))
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debug
        menu.addItem(debugItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func showWindow<V: View>(_ view: V) {
        promptWindow?.close()
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false
        promptWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showStartOfDayPrompt() {
        var presented = true
        let view = StartOfDayView(isPresented: Binding(get: { presented }, set: { [weak self] v in
            presented = v; if !v { self?.promptWindow?.close() }
        })) { [weak self] excitement in
            DataStore.shared.add(Response(timestamp: Date(), type: .startOfDay, excitement: excitement))
            self?.wakeDetector.markTodayAsPrompted()
        }
        showWindow(view)
    }

    @objc private func showIntradayPrompt() {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= scheduler.workingHoursStart && hour < scheduler.workingHoursEnd else { return }

        var presented = true
        let view = IntradayView(isPresented: Binding(get: { presented }, set: { [weak self] v in
            presented = v; if !v { self?.promptWindow?.close() }
        })) { activity, excitement in
            DataStore.shared.add(Response(timestamp: Date(), type: .intraday, excitement: excitement, activity: activity))
        }
        showWindow(view)
    }

    @objc private func showHistory() { showWindow(HistoryView()) }
    @objc private func showSettings() { showWindow(SettingsView()) }
    @objc private func resetStartOfDay() { wakeDetector.reset() }

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
