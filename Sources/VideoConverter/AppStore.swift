import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ConverterCore

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case queue = "Convert", logs = "Logs", metrics = "Metrics", engine = "Engine"
    var id: Self { self }
    var icon: String {
        switch self { case .queue: "square.stack.3d.up"; case .logs: "text.alignleft"; case .metrics: "waveform.path.ecg"; case .engine: "gearshape.2" }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var snapshot = EngineSnapshot()
    @Published var selection: Set<UUID> = []
    @Published var tab: WorkspaceTab = .queue {
        didSet {
            let name = tab.rawValue
            Task { await engine.recordPerformance(name: "ui_tab", durationMs: 0, detail: name) }
        }
    }
    @Published var settings = ConversionSettings()
    @Published var feedback: String?
    @Published var search = ""
    @Published var stateFilter: JobState?
    @Published var toolDirectory = ""
    @Published var preset: ConversionPreset = .balanced
    @Published var isShuttingDown = false
    let engine = ConversionEngine(sessionLabel: ProcessInfo.processInfo.environment["VIDEOCONVERTER_SESSION_LABEL"] ?? "application")
    private let commands: AsyncStream<AppCommand>.Continuation
    private var commandTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    var activeJobs: [ConversionJob] { snapshot.jobs.filter { $0.state.isActive } }
    var selectedJobs: [ConversionJob] { snapshot.jobs.filter { selection.contains($0.id) } }
    var visibleJobs: [ConversionJob] {
        snapshot.jobs.filter { (stateFilter == nil || $0.state == stateFilter) && (search.isEmpty || $0.input.lastPathComponent.localizedCaseInsensitiveContains(search)) }
    }

    init() {
        let channel = AsyncStream<AppCommand>.makeStream()
        commands = channel.continuation
        if let data = UserDefaults.standard.data(forKey: "defaultSettings"), let saved = try? JSONDecoder().decode(ConversionSettings.self, from: data) { settings = saved }
        let engine = engine
        commandTask = Task { for await command in channel.stream { await engine.handle(command) } }
        snapshotTask = Task { [weak self] in
            for await snapshot in engine.snapshots {
                guard let self else { return }
                self.snapshot = snapshot
                let pruned = self.selection.intersection(Set(snapshot.jobs.map(\.id)))
                if pruned != self.selection { self.selection = pruned }
                let active = snapshot.jobs.filter { $0.state == .running }.count
                let badge = active > 0 ? "\(active)" : nil
                if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
                let deliveryMs = max(0, Date().timeIntervalSince(snapshot.publishedAt) * 1000)
                Task { await engine.recordPerformance(name: "ui_snapshot_delivery", durationMs: deliveryMs) }
            }
        }
        heartbeatTask = Task {
            while !Task.isCancelled {
                let start = ProcessInfo.processInfo.systemUptime
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let delay = max(0, (ProcessInfo.processInfo.systemUptime - start) * 1000 - 100)
                await engine.recordPerformance(name: "ui_heartbeat_lag", durationMs: delay)
            }
        }
        send(.initialize)
    }

    func send(_ command: AppCommand) { guard !isShuttingDown else { return }; commands.yield(command) }
    func importFiles(folder: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder; panel.canChooseDirectories = folder; panel.allowsMultipleSelection = true
        panel.message = folder ? "Add all regular files recursively. Non-media files are reported individually." : "Choose video or audio files. Their formats are detected automatically."
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.send(.add(panel.urls, self.settings))
        }
    }
    func chooseOutputFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in if response == .OK, let url = panel.url { self?.settings.outputDirectory = url.path } }
    }
    func chooseTools() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose a directory containing executable ffmpeg and ffprobe tools."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.toolDirectory = url.path; self.send(.setTools(url.path))
        }
    }
    func usePreset(_ preset: ConversionPreset) {
        let folder = settings.outputDirectory, suffix = settings.suffix
        settings = preset.settings; settings.outputDirectory = folder; settings.suffix = suffix
        self.preset = preset
    }
    func loadSelectedSettings() { if selectedJobs.count == 1, let job = selectedJobs.first { settings = job.settings } }
    func applySettings() {
        send(.apply(selection, settings))
        saveDefaults()
    }
    func saveDefaults() { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "defaultSettings") } }
    func reveal(_ job: ConversionJob) {
        NSWorkspace.shared.activateFileViewerSelecting([job.state == .completed ? (job.output ?? job.input) : job.input])
    }
    func preview(_ job: ConversionJob) { NSWorkspace.shared.open(job.state == .completed ? (job.output ?? job.input) : job.input) }
    func exportText(_ text: String, name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.allowedContentTypes = name.hasSuffix(".csv") ? [.commaSeparatedText] : [.plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { [weak self] in
                do { try await Task.detached(priority: .utility) { try text.write(to: url, atomically: true, encoding: .utf8) }.value }
                catch { self?.feedback = error.localizedDescription }
            }
        }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func exportQueueReport() {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = snapshot.jobs.map { job in
            [job.id.uuidString, job.input.path, job.output?.path ?? "", job.state.rawValue,
             job.settings.format.rawValue, String(job.warningCount), job.message,
             job.createdAt.ISO8601Format(), job.finishedAt?.ISO8601Format() ?? "",
             String(job.chunkProgress?.workers ?? 1), String(job.chunkProgress?.segments.count ?? 0),
             String(job.chunkProgress?.completed ?? 0)].map(quote).joined(separator: ",")
        }
        exportText("id,input,output,status,format,diagnostics,message,created,finished,worker_slots,chunks,verified_chunks\n" + rows.joined(separator: "\n"), name: "VideoConverter-queue.csv")
    }
    func shutdown() async {
        isShuttingDown = true
        heartbeatTask?.cancel()
        commands.finish()
        // Drain accepted commands before shutdown, so a delayed click cannot restart a worker.
        await commandTask?.value
        await engine.shutdown()
        snapshotTask?.cancel()
    }
}

extension Double {
    var durationLabel: String {
        guard isFinite, self >= 0 else { return "—" }
        let seconds = Int(min(self, 359_999_999))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
func byteLabel(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
