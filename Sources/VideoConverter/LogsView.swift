import SwiftUI
import ConverterCore

struct LogsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""
    @State private var level: LogLevel?
    @State private var selectedOnly = false
    @State private var follow = true
    private var entries: [LogEntry] {
        store.snapshot.logs.filter {
            (level == nil || $0.level == level) && (!selectedOnly || $0.jobID.map { store.selection.contains($0) } == true) &&
            (search.isEmpty || $0.message.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle(eyebrow: "Everything, explained", title: "Application logs", subtitle: "Commands, decoder diagnostics, and job events in one place.")
            HStack {
                TextField("Search logs…", text: $search).textFieldStyle(.roundedBorder)
                Picker("Level", selection: $level) {
                    Text("All levels").tag(nil as LogLevel?)
                    ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }.frame(width: 175)
                Toggle("Selected jobs", isOn: $selectedOnly).toggleStyle(.checkbox)
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Button("Export…") { store.exportText(exportText, name: "VideoConverter-logs.txt") }
                Button("Clear view") { store.send(.clearLogs) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                Text(entry.date, format: .dateTime.hour().minute().second()).foregroundStyle(.tertiary).frame(width: 85, alignment: .leading)
                                Text(entry.level.rawValue.uppercased()).foregroundStyle(color(entry.level)).frame(width: 65, alignment: .leading)
                                Text(entry.jobID.map { String($0.uuidString.prefix(8)) } ?? "APP").foregroundStyle(.secondary).frame(width: 75, alignment: .leading)
                                Text(entry.message).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }.font(.system(size: 11, design: .monospaced)).padding(.vertical, 8).padding(.horizontal, 12)
                                .background(entry.level == .error ? Color.red.opacity(0.045) : .clear)
                                .id(entry.id)
                            Divider().opacity(0.35)
                        }
                        Color.clear.frame(height: 1).id("log-bottom")
                    }
                }.background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                    .onChange(of: store.snapshot.logs.last?.id) { _, _ in if follow { proxy.scrollTo("log-bottom", anchor: .bottom) } }
            }
            HStack {
                Text("\(entries.count) shown · up to 2,000 entries in memory").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open log folder") { NSWorkspace.shared.open(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoConverter")) }
            }
            Text("Logs are also recorded in local SQLite. Text logs rotate at 5 MB with one previous file. Clearing the view leaves stored history intact. Diagnostics can include filenames and media metadata.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28)
    }
    private var exportText: String {
        entries.map { "\($0.date.ISO8601Format()) [\($0.level.rawValue)] [\($0.jobID?.uuidString ?? "app")] \($0.message)" }.joined(separator: "\n")
    }
    private func color(_ level: LogLevel) -> Color {
        switch level { case .error: .red; case .warning: .orange; case .info: .cyan; case .debug: .secondary }
    }
}
