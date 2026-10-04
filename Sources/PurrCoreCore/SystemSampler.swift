import Darwin
import Foundation
import IOKit

public actor SystemSampler {
    private struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var total: UInt64 { user + system + idle + nice }
        var busy: UInt64 { user + system + nice }
    }

    private struct ProcessKey: Hashable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private struct PreviousProcessValue {
        let totalNanoseconds: UInt64
        let timestamp: TimeInterval
    }

    private struct ProcessAccumulator {
        let descriptor: ProcessDescriptor
        var cpuPercent: Double
        var residentBytes: UInt64
        var processCount: Int
    }

    private var previousCPUTicks: CPUTicks?
    private var networkRates = CounterRateCalculator()
    private var diskRates = CounterRateCalculator()
    private var previousProcesses: [ProcessKey: PreviousProcessValue] = [:]
    private var descriptorCache: [String: ProcessDescriptor] = [:]
    private var lastProcessGroups: [ProcessGroupSample] = []
    private let humanizer = ProcessHumanizer()

    public init() {}

    public func sample(includeProcesses: Bool) -> SystemSnapshot {
        let date = Date()
        let timestamp = date.timeIntervalSince1970
        let cpu = sampleCPU()
        let memory = sampleMemory()
        let networkTotals = sampleNetworkTotals()
        let diskTotals = sampleDiskTotals()
        let network = networkRates.update(
            downloadTotal: networkTotals.read,
            uploadTotal: networkTotals.write,
            timestamp: timestamp
        )
        let disk = diskRates.update(
            downloadTotal: diskTotals.read,
            uploadTotal: diskTotals.write,
            timestamp: timestamp
        )

        if includeProcesses {
            lastProcessGroups = sampleProcesses(timestamp: timestamp)
        }

        return SystemSnapshot(
            timestamp: date,
            cpuPercent: cpu,
            memory: memory,
            network: network,
            disk: disk,
            thermalState: thermalState(),
            processes: lastProcessGroups
        )
    }

    private func sampleCPU() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let current = CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { previousCPUTicks = current }
        guard let previousCPUTicks, current.total >= previousCPUTicks.total else { return 0 }

        let totalDelta = current.total - previousCPUTicks.total
        let busyDelta = current.busy >= previousCPUTicks.busy ? current.busy - previousCPUTicks.busy : 0
        guard totalDelta > 0 else { return 0 }
        return min(max(Double(busyDelta) / Double(totalDelta) * 100, 0), 100)
    }

    private func sampleMemory() -> MemorySnapshot {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else {
            return MemorySnapshot(
                totalBytes: total,
                usedBytes: 0,
                appBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                cachedBytes: 0,
                swapUsedBytes: sampleSwapUsed(),
                pressure: .normal
            )
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        let free = UInt64(statistics.free_count + statistics.speculative_count) * page
        let cached = UInt64(statistics.inactive_count + statistics.purgeable_count) * page
        let wired = UInt64(statistics.wire_count) * page
        let compressed = UInt64(statistics.compressor_page_count) * page
        let app = UInt64(statistics.active_count) * page
        let reclaimable = min(free + cached, total)
        let used = total - reclaimable
        let availableFraction = total > 0 ? Double(reclaimable) / Double(total) : 1
        let pressure: MemoryPressureLevel
        if availableFraction < 0.075 {
            pressure = .critical
        } else if availableFraction < 0.15 {
            pressure = .warning
        } else {
            pressure = .normal
        }

        return MemorySnapshot(
            totalBytes: total,
            usedBytes: used,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: cached,
            swapUsedBytes: sampleSwapUsed(),
            pressure: pressure
        )
    }

    private func sampleSwapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private func sampleNetworkTotals() -> (read: UInt64, write: UInt64) {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return (0, 0) }
        defer { freeifaddrs(firstAddress) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            let interface = current.pointee
            if
                let address = interface.ifa_addr,
                Int32(address.pointee.sa_family) == AF_LINK,
                interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                let dataPointer = interface.ifa_data
            {
                let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                read &+= UInt64(data.ifi_ibytes)
                write &+= UInt64(data.ifi_obytes)
            }
            cursor = interface.ifa_next
        }
        return (read, write)
    }

    private func sampleDiskTotals() -> (read: UInt64, write: UInt64) {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return (0, 0) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let property = IORegistryEntryCreateCFProperty(
                service,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] {
                read &+= (property["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write &+= (property["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, write)
    }

    private func sampleProcesses(timestamp: TimeInterval) -> [ProcessGroupSample] {
        let requestedCapacity = max(Int(proc_listallpids(nil, 0)), 512) + 64
        var pids = [pid_t](repeating: 0, count: requestedCapacity)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return lastProcessGroups }

        var currentValues: [ProcessKey: PreviousProcessValue] = [:]
        var groups: [String: ProcessAccumulator] = [:]

        for pid in pids.prefix(Int(count)) where pid > 0 {
            var bsdInfo = proc_bsdinfo()
            let bsdBytes = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &bsdInfo,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard bsdBytes == MemoryLayout<proc_bsdinfo>.size else { continue }

            var taskInfo = proc_taskinfo()
            let taskBytes = proc_pidinfo(
                pid,
                PROC_PIDTASKINFO,
                0,
                &taskInfo,
                Int32(MemoryLayout<proc_taskinfo>.size)
            )
            guard taskBytes == MemoryLayout<proc_taskinfo>.size else { continue }

            let key = ProcessKey(
                pid: pid,
                startSeconds: bsdInfo.pbi_start_tvsec,
                startMicroseconds: bsdInfo.pbi_start_tvusec
            )
            let totalNanoseconds = taskInfo.pti_total_user &+ taskInfo.pti_total_system
            let current = PreviousProcessValue(totalNanoseconds: totalNanoseconds, timestamp: timestamp)
            currentValues[key] = current

            let cpuPercent: Double
            if
                let previous = previousProcesses[key],
                timestamp > previous.timestamp,
                totalNanoseconds >= previous.totalNanoseconds
            {
                let elapsed = timestamp - previous.timestamp
                cpuPercent = Double(totalNanoseconds - previous.totalNanoseconds) / 1_000_000_000 / elapsed * 100
            } else {
                cpuPercent = 0
            }

            let name = processName(from: &bsdInfo)
            let path = processPath(pid: pid)
            let cacheKey = path.isEmpty ? name : path
            let descriptor: ProcessDescriptor
            if let cached = descriptorCache[cacheKey] {
                descriptor = cached
            } else {
                descriptor = humanizer.describe(executableName: name, path: path)
                descriptorCache[cacheKey] = descriptor
            }

            var accumulator = groups[descriptor.groupKey] ?? ProcessAccumulator(
                descriptor: descriptor,
                cpuPercent: 0,
                residentBytes: 0,
                processCount: 0
            )
            accumulator.cpuPercent += max(cpuPercent, 0)
            accumulator.residentBytes &+= taskInfo.pti_resident_size
            accumulator.processCount += 1
            groups[descriptor.groupKey] = accumulator
        }

        previousProcesses = currentValues
        if descriptorCache.count > 2_000 {
            descriptorCache.removeAll(keepingCapacity: true)
        }

        let allSamples = groups.values.map { value in
            ProcessGroupSample(
                groupKey: value.descriptor.groupKey,
                displayName: value.descriptor.displayName,
                explanation: value.descriptor.explanation,
                category: value.descriptor.category,
                cpuPercent: value.cpuPercent,
                residentBytes: value.residentBytes,
                processCount: value.processCount
            )
        }
        let cpuLeaders = allSamples.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(20)
        let memoryLeaders = allSamples.sorted { $0.residentBytes > $1.residentBytes }.prefix(20)
        var selected: [String: ProcessGroupSample] = [:]
        for sample in cpuLeaders { selected[sample.groupKey] = sample }
        for sample in memoryLeaders { selected[sample.groupKey] = sample }
        return selected.values.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private func processName(from info: inout proc_bsdinfo) -> String {
        let primary = withUnsafeBytes(of: &info.pbi_name) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        if !primary.isEmpty { return primary }
        return withUnsafeBytes(of: &info.pbi_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private func processPath(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    private func thermalState() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }
}
