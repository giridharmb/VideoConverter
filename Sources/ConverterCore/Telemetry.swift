import Foundation
import Darwin

public struct MetricSample: Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public var appCPU: Double = 0
    public var workerCPU: Double = 0
    public var appMemory: UInt64 = 0
    public var workerMemory: UInt64 = 0
    public var readBytesPerSecond: Double = 0
    public var writeBytesPerSecond: Double = 0
    public var threads: Int = 0
    public var activeWorkers: Int = 0
    public var thermalState = "Nominal"
    public var availableDisk: Int64 = 0
    public var unavailableProcesses: Int = 0
    public init(date: Date = Date()) { self.date = date }
}

public struct TelemetrySampler: Sendable {
    private struct Counters: Sendable { let cpu: UInt64; let read: UInt64; let written: UInt64; let uptime: Double }
    private var previous: [Int32: Counters] = [:]
    private let secondsPerTick: Double
    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(max(1, timebase.denom)) / 1_000_000_000
    }

    public mutating func sample(pids: [Int32], diskURL: URL) -> MetricSample {
        var sample = MetricSample()
        let appPID = getpid()
        let all = [appPID] + pids.filter { $0 != appPID }
        let now = ProcessInfo.processInfo.systemUptime
        for pid in all {
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { sample.unavailableProcesses += 1; continue }
            let current = Counters(cpu: usage.ri_user_time + usage.ri_system_time,
                                   read: usage.ri_diskio_bytesread, written: usage.ri_diskio_byteswritten, uptime: now)
            var cpu: Double = 0
            if let old = previous[pid] {
                let elapsed = max(0.001, now - old.uptime)
                // rusage_info CPU times use Mach ticks; treating them as nanoseconds undercounts on Apple Silicon.
                cpu = Double(current.cpu >= old.cpu ? current.cpu - old.cpu : 0) * secondsPerTick / elapsed * 100
                sample.readBytesPerSecond += Double(current.read >= old.read ? current.read - old.read : 0) / elapsed
                sample.writeBytesPerSecond += Double(current.written >= old.written ? current.written - old.written : 0) / elapsed
            }
            previous[pid] = current
            if pid == appPID { sample.appCPU = cpu; sample.appMemory = usage.ri_phys_footprint }
            else { sample.workerCPU += cpu; sample.workerMemory += usage.ri_phys_footprint; sample.activeWorkers += 1 }
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size { sample.threads += Int(task.pti_threadnum) }
        }
        previous = previous.filter { all.contains($0.key) }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: sample.thermalState = "Nominal"
        case .fair: sample.thermalState = "Fair"
        case .serious: sample.thermalState = "Serious"
        case .critical: sample.thermalState = "Critical"
        @unknown default: sample.thermalState = "Unknown"
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: diskURL.path),
           let bytes = attributes[.systemFreeSize] as? NSNumber { sample.availableDisk = bytes.int64Value }
        return sample
    }
}
