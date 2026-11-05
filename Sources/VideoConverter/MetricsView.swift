import SwiftUI
import Charts
import ConverterCore

struct MetricsView: View {
    @EnvironmentObject private var store: AppStore
    private var current: MetricSample { store.snapshot.metrics.last ?? MetricSample() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    SectionTitle(eyebrow: "Live observability", title: "See the whole workload.", subtitle: "App and FFmpeg workers · sampled about once per second · local only")
                    Spacer()
                    Button("Export CSV…") { store.exportText(csv, name: "VideoConverter-metrics.csv") }
                }
                HStack(spacing: 12) {
                    StatCard(title: "CPU · 100% = one core", value: String(format: "%.1f%%", current.appCPU + current.workerCPU), icon: "cpu")
                    StatCard(title: "Memory footprint", value: byteLabel(Int64(clamping: current.appMemory + current.workerMemory)), icon: "memorychip", color: .purple)
                    StatCard(title: "Disk write / sec", value: byteLabel(Int64(current.writeBytesPerSecond)), icon: "externaldrive.badge.plus", color: .orange)
                }
                HStack(alignment: .top, spacing: 16) {
                    chartCard("CPU utilization", subtitle: "App + active workers · % of one logical core") {
                        Chart(store.snapshot.metrics) { sample in
                            LineMark(x: .value("Time", sample.date), y: .value("CPU", sample.appCPU), series: .value("Process", "App")).foregroundStyle(by: .value("Process", "App"))
                            LineMark(x: .value("Time", sample.date), y: .value("CPU", sample.workerCPU), series: .value("Process", "Workers")).foregroundStyle(by: .value("Process", "Workers"))
                        }.chartForegroundStyleScale(["App": Color.cyan, "Workers": Color.purple])
                    }
                    chartCard("Memory footprint", subtitle: "Physical footprint · MiB") {
                        Chart(store.snapshot.metrics) { sample in
                            AreaMark(x: .value("Time", sample.date), y: .value("MiB", Double(sample.appMemory + sample.workerMemory) / 1_048_576))
                                .foregroundStyle(LinearGradient(colors: [.purple.opacity(0.5), .purple.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Time", sample.date), y: .value("MiB", Double(sample.appMemory + sample.workerMemory) / 1_048_576)).foregroundStyle(.purple)
                        }
                    }
                }
                chartCard("Disk I/O throughput", subtitle: "Kernel-accounted physical reads and writes · MiB/s · cache hits may read as zero") {
                    Chart(store.snapshot.metrics) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("MiB/s", sample.readBytesPerSecond / 1_048_576), series: .value("Direction", "Read")).foregroundStyle(by: .value("Direction", "Read"))
                        LineMark(x: .value("Time", sample.date), y: .value("MiB/s", sample.writeBytesPerSecond / 1_048_576), series: .value("Direction", "Write")).foregroundStyle(by: .value("Direction", "Write"))
                    }.chartForegroundStyleScale(["Read": Color.cyan, "Write": Color.orange])
                }
                HStack(spacing: 12) {
                    StatCard(title: "Worker processes", value: "\(current.activeWorkers)", icon: "gearshape.2")
                    StatCard(title: "Threads · app + workers", value: "\(current.threads)", icon: "point.3.connected.trianglepath.dotted", color: .purple)
                    StatCard(title: "Thermal state", value: current.thermalState, icon: "thermometer.medium", color: current.thermalState == "Nominal" ? .green : .orange)
                    StatCard(title: "Destination disk free", value: byteLabel(current.availableDisk), icon: "externaldrive", color: .green)
                }
                HStack(spacing: 24) {
                    Label("\(store.snapshot.jobs.filter { $0.state == .completed }.count) completed", systemImage: "checkmark.circle").foregroundStyle(.green)
                    Label("\(store.snapshot.jobs.filter { $0.state == .failed }.count) failed", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    Label("\(store.snapshot.jobs.reduce(0) { $0 + $1.warningCount }) diagnostics", systemImage: "text.bubble").foregroundStyle(.orange)
                    Spacer()
                }.font(.callout)
                Text("A rolling 300-sample history is retained. First samples establish a baseline. Completed workers disappear from live totals; short-lived probes may fall between samples. Unavailable process counters: \(current.unavailableProcesses). GPU, network, power draw, and system-wide I/O are not measured.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
    private func chartCard<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            content().frame(height: 155).chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }.chartYAxis { AxisMarks(position: .leading) }.padding(.top, 8)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
    private var csv: String {
        "timestamp,app_cpu_percent,worker_cpu_percent,app_memory_bytes,worker_memory_bytes,read_bytes_per_second,write_bytes_per_second,threads,workers,thermal,available_disk_bytes,unavailable_processes\n" + store.snapshot.metrics.map {
            "\($0.date.ISO8601Format()),\($0.appCPU),\($0.workerCPU),\($0.appMemory),\($0.workerMemory),\($0.readBytesPerSecond),\($0.writeBytesPerSecond),\($0.threads),\($0.activeWorkers),\($0.thermalState),\($0.availableDisk),\($0.unavailableProcesses)"
        }.joined(separator: "\n")
    }
}
