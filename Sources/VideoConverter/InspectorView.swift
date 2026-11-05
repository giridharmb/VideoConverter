import SwiftUI
import ConverterCore

struct InspectorView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pane = "Output"
    @State private var reviewedCommand = ""
    @State private var reviewing = false
    private var editableCount: Int { store.selectedJobs.filter { !$0.state.isActive && $0.state != .completed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Conversion settings").font(.title3.weight(.semibold))
                    Spacer()
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.cyan)
                }
                Text(store.selection.isEmpty ? "Defaults for new imports" : "\(store.selection.count) selected · \(editableCount) editable")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Quick preset", selection: Binding(get: { store.preset }, set: { store.usePreset($0) })) {
                    ForEach(ConversionPreset.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().padding(.top, 8)
            }.padding(20)
            Divider()
            if let job = store.selectedJobs.first, store.selection.count == 1, let media = job.media {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.input.lastPathComponent).fontWeight(.medium).textSelection(.enabled)
                        Text("\(media.format) · \(media.duration.durationLabel) · \(byteLabel(media.size))")
                        if media.bitRate > 0 { Text("\(media.bitRate / 1000) kb/s total bitrate") }
                        ForEach(media.streams) { Text($0.summary).textSelection(.enabled) }
                        HStack {
                            Button("Open") { store.preview(job) }
                            Button("Finder") { store.reveal(job) }
                        }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                } label: { Label("Detected media", systemImage: "waveform.path").font(.caption.weight(.medium)) }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
            }
            Picker("Settings category", selection: $pane) {
                ForEach(["Output", "Video", "Audio", "Expert"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(14)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch pane {
                    case "Video": videoSettings
                    case "Audio": audioSettings
                    case "Expert": expertSettings
                    default: outputSettings
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
            Divider()
            VStack(spacing: 9) {
                if !store.selection.isEmpty {
                    Button { store.applySettings() } label: {
                        Text("Apply to \(editableCount) selected jobs").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(editableCount == 0)
                }
                Button { store.saveDefaults() } label: { Text("Save defaults for new imports").frame(maxWidth: .infinity) }
                Text("Changes apply when you press Apply. Active and completed jobs keep their settings.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(16)
        }
        .background(.background.opacity(0.55))
        .onChange(of: store.selection) { _, _ in store.loadSelectedSettings(); reviewedCommand = "" }
    }

    private var outputSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsHeader("Destination", icon: "externaldrive")
            Picker("Container", selection: Binding(get: { store.settings.format }, set: { format in
                store.settings.format = format
                store.settings.audioCodec = format.defaultAudioCodec
                if format == .webm { store.settings.videoCodec = "libvpx-vp9" }
                else if store.settings.videoCodec == "libvpx-vp9" { store.settings.videoCodec = "libx264" }
            })) {
                ForEach(OutputFormat.allCases) { Text($0.rawValue.uppercased() + ($0.audioOnly ? " · Audio" : " · Video")).tag($0) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Output folder").font(.caption.weight(.medium))
                Text(store.settings.outputDirectory.isEmpty ? "Alongside each source file" : store.settings.outputDirectory)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                HStack {
                    Button("Choose folder…") { store.chooseOutputFolder() }
                    if !store.settings.outputDirectory.isEmpty { Button("Reset") { store.settings.outputDirectory = "" } }
                }
                TextField("Filename suffix", text: $store.settings.suffix).textFieldStyle(.roundedBorder)
                helpText("Existing files are preserved. A number is added if a destination name is already taken.")
            }
            Divider()
            settingsHeader("Time range", icon: "scissors")
            numericField("Start (seconds)", value: $store.settings.startSeconds)
            numericField("Duration (0 = rest)", value: $store.settings.durationSeconds)
            Divider()
            settingsHeader("Compatibility & recovery", icon: "shield.lefthalf.filled")
            Toggle("Recover from damaged packets", isOn: $store.settings.recoverCorruption)
            helpText("Discard corrupt packets and continue decoding where possible. Unrecoverable files still fail; other jobs continue.")
            Toggle("Preserve metadata & chapters", isOn: $store.settings.preserveMetadata)
            Toggle("Optimize MP4/MOV for streaming", isOn: $store.settings.fastStart)
            Toggle("Include subtitles", isOn: $store.settings.subtitles)
            helpText("Text subtitles become mov_text in MP4/MOV. Bitmap subtitles and incompatible stream/container combinations may need another container or expert options.")
        }.font(.callout)
    }

    private var videoSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsHeader("Video encoding", icon: "film")
            Toggle("Convert this file in parallel chunks", isOn: Binding(
                get: { store.settings.chunking != nil },
                set: { store.settings.chunking = $0 ? ChunkSettings() : nil }))
            if store.settings.chunking != nil {
                Picker("Chunk workers", selection: Binding(get: { store.settings.chunking?.workers ?? 4 }, set: { store.settings.chunking?.workers = $0 })) {
                    ForEach(2...8, id: \.self) { Text("Up to \($0)").tag($0) }
                }
                numericField("Chunk length (seconds)", value: Binding(get: { store.settings.chunking?.seconds ?? 120 }, set: { store.settings.chunking?.seconds = $0 }))
                helpText("1–3600 seconds per chunk. Workers share the queue's worker slots; increase that limit to use more cores for one file. Audio is encoded once during joining. Temporary video chunks need extra disk space.")
                helpText("MP4/MKV/MOV with libx264 or libx265. Output is constant frame rate; trims align to frames. Subtitles, audio copy, deinterlacing, custom video filters and expert arguments require standard mode. More workers may use more memory without being faster.")
                Divider()
            }
            if store.settings.format.audioOnly { helpText("Video is excluded by the selected audio container.") }
            Picker("Encoder", selection: $store.settings.videoCodec) {
                ForEach(["libx264", "libx265", "h264_videotoolbox", "hevc_videotoolbox", "libvpx-vp9", "libaom-av1", "mpeg4", "prores_ks", "copy"], id: \.self) { Text($0).tag($0) }
            }
            TextField("Custom encoder name", text: $store.settings.videoCodec).textFieldStyle(.roundedBorder)
            helpText("Encoder availability depends on FFmpeg. View the Engine tab for detected capabilities. Copy remuxes without re-encoding.")
            HStack { Text("Quality (CRF)"); Spacer(); Text("\(store.settings.quality)").monospacedDigit().foregroundStyle(.cyan) }
            Slider(value: Binding(get: { Double(store.settings.quality) }, set: { store.settings.quality = Int($0) }), in: 0...51, step: 1)
                .accessibilityLabel("CRF quality")
            helpText("Lower values improve quality and increase size. Bitrate overrides CRF. Hardware encoders default to 6000k when no bitrate is set.")
            labelledField("Video bitrate", placeholder: "Auto · e.g. 6000k", text: $store.settings.videoBitrate)
            Picker("Encoding speed", selection: $store.settings.encoderPreset) {
                ForEach(["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"], id: \.self) { Text($0).tag($0) }
            }
            Divider()
            settingsHeader("Picture & streams", icon: "aspectratio")
            if let media = store.selectedJobs.first?.media, store.selection.count == 1 {
                Picker("Video stream", selection: $store.settings.videoStream) {
                    Text("First video stream").tag(nil as Int?)
                    ForEach(media.streams.filter { $0.kind == "video" }) { Text($0.summary).tag(Optional($0.index)) }
                }
            }
            numericField("Width (0 = auto)", value: $store.settings.width)
            numericField("Height (0 = auto)", value: $store.settings.height)
            helpText("Both zero preserve the original size. One zero preserves aspect ratio using an even dimension.")
            labelledField("Frame rate", placeholder: "Source · e.g. 30000/1001", text: $store.settings.frameRate)
            Toggle("Deinterlace", isOn: $store.settings.deinterlace)
            labelledField("Video filter chain", placeholder: "e.g. crop=1280:720", text: $store.settings.videoFilter)
            helpText("FFmpeg filter syntax. Filters are applied after deinterlacing and scaling; they require re-encoding.")
        }.font(.callout)
    }

    private var audioSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsHeader("Audio encoding", icon: "waveform")
            Toggle("Exclude audio (mute)", isOn: $store.settings.mute)
            Picker("Encoder", selection: $store.settings.audioCodec) {
                ForEach(["aac", "libmp3lame", "libopus", "libvorbis", "flac", "pcm_s16le", "alac", "copy"], id: \.self) { Text($0).tag($0) }
            }
            TextField("Custom encoder name", text: $store.settings.audioCodec).textFieldStyle(.roundedBorder)
            labelledField("Audio bitrate", placeholder: "e.g. 192k", text: $store.settings.audioBitrate)
            Picker("Sample rate", selection: $store.settings.sampleRate) {
                Text("Source").tag(0)
                ForEach([22050, 44100, 48000, 96000], id: \.self) { Text("\($0) Hz").tag($0) }
            }
            Picker("Channels", selection: $store.settings.channels) {
                Text("Source").tag(0); Text("Mono").tag(1); Text("Stereo").tag(2); Text("5.1").tag(6); Text("7.1").tag(8)
            }
            Divider()
            settingsHeader("Streams & processing", icon: "slider.horizontal.3")
            if let media = store.selectedJobs.first?.media, store.selection.count == 1 {
                Picker("Audio stream", selection: $store.settings.audioStream) {
                    Text("First audio stream").tag(nil as Int?)
                    ForEach(media.streams.filter { $0.kind == "audio" }) { Text($0.summary).tag(Optional($0.index)) }
                }
            }
            Toggle("Include all audio tracks", isOn: $store.settings.allAudio)
            helpText("Video containers can keep multiple tracks. Audio-only outputs use the selected or first audio track.")
            Toggle("Normalize loudness (EBU R128)", isOn: $store.settings.normalizeAudio)
            helpText("Uses FFmpeg single-pass loudnorm. For measured two-pass mastering, use a dedicated analysis workflow.")
            labelledField("Audio filter chain", placeholder: "e.g. volume=0.8", text: $store.settings.audioFilter)
        }.font(.callout)
    }

    private var expertSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsHeader("FFmpeg controls", icon: "terminal")
            numericField("Threads (0 = automatic)", value: $store.settings.threads)
            helpText("Per-encoder thread hint. Some encoders manage their own thread pools. High parallelism can increase memory and thermal load.")
            argumentEditor("Before input", text: $store.settings.extraInputArguments)
            argumentEditor("Before output", text: $store.settings.extraOutputArguments)
            helpText("Enter JSON arrays of individual arguments, for example [\"-g\", \"60\"]. No shell is used. Advanced options can override generated settings and may write side files. Input, overwrite and progress flags are reserved. Use local, trusted inputs and options.")
            Link("FFmpeg option reference ↗", destination: URL(string: "https://ffmpeg.org/ffmpeg-all.html")!)
            Divider()
            settingsHeader("Review command", icon: "doc.text.magnifyingglass")
            Button(reviewing ? "Building preview…" : "Build command preview") { review() }
                .disabled(reviewing || store.selectedJobs.count != 1 || store.selectedJobs.first?.media == nil)
            helpText("Select an inspected file to preview with the current settings. The actual destination is reserved when the job starts.")
            if !reviewedCommand.isEmpty {
                Text(reviewedCommand).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                Button("Copy preview") { store.copy(reviewedCommand) }
            }
        }.font(.callout)
    }
    private func review() {
        guard var job = store.selectedJobs.first else { return }
        job.settings = store.settings
        let previewJob = job
        let executable = store.snapshot.tools?.ffmpeg.path ?? "ffmpeg"
        reviewing = true
        Task {
            do {
                reviewedCommand = try await Task.detached(priority: .utility) {
                    let plan = try CommandBuilder.make(job: previewJob)
                    if let chunks = plan.chunks {
                        return "\(chunks.segments.count) video chunks · up to \(chunks.workers) workers, limited by queue slots\nFirst chunk:\n" + CommandBuilder.display([executable] + chunks.segments[0].arguments)
                            + "\n\nThen join verified chunks and encode continuous audio:\n" + CommandBuilder.display([executable] + chunks.joinArguments)
                    }
                    return CommandBuilder.display([executable] + plan.arguments)
                }.value
            } catch { reviewedCommand = error.localizedDescription }
            reviewing = false
        }
    }
    private func settingsHeader(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }
    private func helpText(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func labelledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(label).font(.caption); TextField(placeholder, text: text).textFieldStyle(.roundedBorder) }
    }
    private func numericField(_ label: String, value: Binding<Int>) -> some View {
        HStack { Text(label).font(.caption); Spacer(); TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing) }
    }
    private func numericField(_ label: String, value: Binding<Double>) -> some View {
        HStack { Text(label).font(.caption); Spacer(); TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing) }
    }
    private func argumentEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium))
            TextEditor(text: text).font(.system(size: 11, design: .monospaced)).frame(height: 85)
                .padding(5).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }
}
