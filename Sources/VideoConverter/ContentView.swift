import SwiftUI
import ConverterCore

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 26)).foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VideoConverter").font(.headline)
                        Text("YOUR MEDIA, REIMAGINED").font(.system(size: 8, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    }
                }.padding(.top, 18)
                VStack(spacing: 6) {
                    ForEach(WorkspaceTab.allCases) { tab in
                        Button { store.tab = tab } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tab.icon).frame(width: 22)
                                Text(tab.rawValue).fontWeight(.medium)
                                Spacer()
                                if tab == .queue { Text("\(store.snapshot.jobs.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            }
                            .padding(11)
                            .background(store.tab == tab ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(tab.rawValue)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    Label(store.snapshot.tools == nil ? "Engine unavailable" : "FFmpeg connected", systemImage: store.snapshot.tools == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(store.snapshot.tools == nil ? .orange : .green)
                    Text("Private by design.\nConversions stay on this Mac.").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                Text("macOS · Swift · FFmpeg").font(.caption2).foregroundStyle(.tertiary)
            }.padding(.horizontal, 16).padding(.bottom, 16)
                .navigationSplitViewColumnWidth(min: 220, ideal: 235, max: 270)
        } detail: {
            VStack(spacing: 0) {
                if let message = store.snapshot.persistenceError ?? store.snapshot.telemetryError {
                    Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                switch store.tab {
                case .queue: QueueView()
                case .logs: LogsView()
                case .metrics: MetricsView()
                case .engine: EngineView()
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.cyan)
        .frame(minWidth: 1150, minHeight: 740)
        .alert("Unable to complete action", isPresented: Binding(get: { store.feedback != nil }, set: { if !$0 { store.feedback = nil } })) {
            Button("OK") { store.feedback = nil }
        } message: { Text(store.feedback ?? "") }
    }
}

struct SectionTitle: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.cyan)
            Text(title).font(.system(size: 29, weight: .bold, design: .rounded))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .cyan
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 34, height: 38).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.quaternary, lineWidth: 1))
    }
}

extension JobState {
    var color: Color {
        switch self { case .completed: .green; case .failed: .red; case .running: .cyan; case .paused: .orange; case .cancelled: .secondary; default: .secondary }
    }
    var icon: String {
        switch self { case .completed: "checkmark.circle.fill"; case .failed: "exclamationmark.circle.fill"; case .running: "arrow.triangle.2.circlepath"; case .paused: "pause.circle.fill"; case .cancelled: "xmark.circle"; case .inspecting: "waveform"; default: "clock" }
    }
}
