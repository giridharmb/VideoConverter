import SwiftUI
import ConverterCore

struct EngineView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""
    private var capabilities: String {
        if search.isEmpty { return store.snapshot.capabilities }
        return store.snapshot.capabilities.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains(search) }.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle(eyebrow: "Built on FFmpeg", title: "Your engine. Your options.", subtitle: "Capabilities are detected from your installed build, including optional codecs and hardware acceleration.")
            VStack(alignment: .leading, spacing: 12) {
                Label(store.snapshot.engineDescription, systemImage: store.snapshot.tools == nil ? "exclamationmark.triangle" : "checkmark.seal")
                    .font(.headline).textSelection(.enabled)
                if let tools = store.snapshot.tools {
                    Text("FFmpeg: \(tools.ffmpeg.path)\nffprobe: \(tools.ffprobe.path)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } else {
                    Text("Install FFmpeg with Homebrew (brew install ffmpeg), or supply a compatible build containing ffmpeg and ffprobe.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose FFmpeg folder…") { store.chooseTools() }
                    Button("Auto-detect again") { store.send(.setTools("")) }
                    Spacer()
                    Link("FFmpeg documentation ↗", destination: URL(string: "https://ffmpeg.org/documentation.html")!)
                }
                Toggle("Keep this Mac awake while converting (display may sleep)", isOn: Binding(get: { store.snapshot.preventSleep }, set: { store.send(.setPreventSleep($0)) }))
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 13))
            TextField("Search encoders, decoders, containers, filters, or hardware backends…", text: $search).textFieldStyle(.roundedBorder)
            ScrollView([.horizontal, .vertical]) {
                Text(capabilities.isEmpty ? "No matching capabilities." : capabilities)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            }.background(.background, in: RoundedRectangle(cornerRadius: 12))
            Text("The app invokes FFmpeg and ffprobe directly, without a shell. FFmpeg loads its codec libraries inside isolated workers. This build uses local tools; distributing a self-contained app requires bundling compatible binaries and their libraries and following their licenses.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28)
    }
}
