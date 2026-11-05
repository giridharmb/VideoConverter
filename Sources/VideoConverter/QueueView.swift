import SwiftUI
import ConverterCore

struct QueueView: View {
    @EnvironmentObject private var store: AppStore
    @State private var dropTargeted = false
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    SectionTitle(eyebrow: "Conversion studio", title: "Make every format fit.", subtitle: "Drop your media. Choose a destination. Keep creating.")
                    Spacer()
                    Menu { Button("Add Media…") { store.importFiles() }; Button("Add Folder…") { store.importFiles(folder: true) } } label: {
                        Label("Add media", systemImage: "plus")
                    }.menuStyle(.borderlessButton).fixedSize().padding(9).background(.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                }
                HStack(spacing: 10) {
                    StatCard(title: "In queue", value: "\(store.snapshot.jobs.filter { !$0.state.isTerminal }.count)", icon: "square.stack")
                    StatCard(title: "Converting", value: "\(store.snapshot.jobs.filter { $0.state == .running }.count)", icon: "bolt.fill")
                    StatCard(title: "Completed", value: "\(store.snapshot.jobs.filter { $0.state == .completed }.count)", icon: "checkmark", color: .green)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find media…", text: $store.search).textFieldStyle(.plain)
                    Picker("Status", selection: $store.stateFilter) {
                        Text("All statuses").tag(nil as JobState?)
                        ForEach(JobState.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }.labelsHidden().frame(width: 135)
                }.padding(8).background(.background, in: RoundedRectangle(cornerRadius: 9))
                if store.snapshot.jobs.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 44, weight: .light)).foregroundStyle(.cyan)
                        Text("Your next conversion starts here").font(.title3.weight(.semibold))
                        Text("Drop videos, audio files, or folders.\nStreams, codecs, and duration are detected automatically.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Choose media…") { store.importFiles() }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.cyan.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.cyan.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [7, 6])))
                } else {
                    List(selection: $store.selection) {
                        ForEach(store.visibleJobs) { job in
                            JobRow(job: job).tag(job.id).contextMenu {
                                Button("Open media") { store.preview(job) }
                                Button("Reveal in Finder") { store.reveal(job) }
                                Divider()
                                Button("Pause") { store.send(.pause([job.id])) }.disabled(job.state != .running)
                                Button("Resume") { store.send(.resume([job.id])) }.disabled(job.state != .paused)
                                Button("Retry") { store.send(.retry([job.id])) }.disabled(![.failed, .cancelled].contains(job.state))
                                Button("Cancel") { store.send(.cancel([job.id])) }.disabled(job.state.isTerminal)
                                Button("Move to front") { store.send(.moveFirst([job.id])) }
                                Button("Duplicate job") { store.send(.duplicate([job.id], job.settings)) }
                                Divider()
                                Button("Copy command") { store.copy(CommandBuilder.display(job.command)) }.disabled(job.command.isEmpty)
                                Button("Remove from queue") { store.send(.remove([job.id])) }.disabled(job.state.isActive)
                            }
                        }
                    }.listStyle(.inset).scrollContentBackground(.hidden)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                        .overlay { if store.visibleJobs.isEmpty { ContentUnavailableView.search(text: store.search) } }
                }
                HStack {
                    Menu {
                        Button("Select all") { store.selection = Set(store.visibleJobs.map(\.id)) }
                        Button("Pause selected") { store.send(.pause(store.selection)) }
                        Button("Resume selected") { store.send(.resume(store.selection)) }
                        Button("Cancel selected") { store.send(.cancel(store.selection)) }
                        Button("Retry selected") { store.send(.retry(store.selection)) }
                        Button("Move selected to front") { store.send(.moveFirst(store.selection)) }
                        Button("Duplicate with current settings") { store.send(.duplicate(store.selection, store.settings)) }
                        Button("Remove selected") { store.send(.remove(store.selection)) }
                        Divider()
                        Button("Clear finished jobs") { store.send(.clearFinished) }
                        Button("Export queue report…") { store.exportQueueReport() }
                    } label: { Label("Bulk actions", systemImage: "checklist") }.fixedSize()
                    Spacer()
                    Text("\(store.selection.count) selected").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 12) {
                    Circle().fill(store.snapshot.queueRunning ? .green : .secondary).frame(width: 6, height: 6)
                    Text(store.snapshot.queueRunning ? "Queue is running" : "Queue is stopped").font(.caption)
                    Spacer()
                    Picker("Parallel", selection: Binding(get: { store.snapshot.concurrency }, set: { store.send(.setConcurrency($0)) })) {
                        ForEach(1...8, id: \.self) { Text("\($0) jobs").tag($0) }
                    }.frame(width: 140).help("Paused jobs retain their slot. FFmpeg can use multiple CPU threads per job.")
                    if store.snapshot.queueRunning {
                        Button("Stop queue") { store.send(.stopScheduling) }.help("Stops launching new jobs; active work continues.")
                    } else {
                        Button { store.send(.start) } label: { Label("Start queue", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).disabled(store.snapshot.tools == nil)
                    }
                }
            }.padding(24).frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 16).stroke(.cyan, lineWidth: 3).padding(8).allowsHitTesting(false) } }
                .dropDestination(for: URL.self) { urls, _ in store.send(.add(urls, store.settings)); return true } isTargeted: { dropTargeted = $0 }
            InspectorView().frame(minWidth: 340, idealWidth: 380, maxWidth: 440)
        }
    }
}

struct JobRow: View {
    let job: ConversionJob
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: job.settings.format.audioOnly ? "waveform" : "film.stack")
                .font(.title2).foregroundStyle(job.state.color)
                .frame(width: 42, height: 48).background(job.state.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(job.input.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(job.input.path)
                    Spacer()
                    Label(job.state.label, systemImage: job.state.icon).font(.caption2).foregroundStyle(job.state.color)
                }
                HStack(spacing: 6) {
                    Text(job.input.pathExtension.uppercased()); Image(systemName: "arrow.right"); Text(job.settings.format.rawValue.uppercased())
                    if let media = job.media { Text("·"); Text(media.duration.durationLabel); Text("·"); Text(byteLabel(media.size)) }
                    Spacer()
                    if job.warningCount > 0 { Label("\(job.warningCount)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }.font(.caption2).foregroundStyle(.secondary)
                if [.running, .paused, .completed].contains(job.state) {
                    ProgressView(value: job.progress.fraction).tint(job.state.color).accessibilityLabel("Conversion progress")
                }
                HStack {
                    Text(job.message).lineLimit(job.state == .failed ? 2 : 1).help(job.message)
                    Spacer()
                    if [.running, .paused].contains(job.state) {
                        Text(String(format: "%.1f× · %.0f fps", job.progress.speed, job.progress.fps))
                        Text(byteLabel(job.progress.bytes))
                        Text("\(Int(job.progress.fraction * 100))%")
                        if let eta = job.progress.eta { Text("~\(eta.durationLabel) left") }
                    }
                }.font(.caption2.monospacedDigit()).foregroundStyle(job.state == .failed ? .red : .secondary)
            }
        }.padding(.vertical, 10).accessibilityElement(children: .contain)
    }
}
