import Darwin
import Foundation
import IOKit

public actor SystemSampler {
    private struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var total: UInt64 { user &+ system &+ idle &+ nice }
        var busy: UInt64 { user &+ system &+ nice }
    }

    private struct ProcessKey: Hashable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private struct PreviousProcessValue {
        let totalMachTicks: UInt64
        let timestamp: TimeInterval
    }

    private struct ProcessAccumulator {
        var descriptor: ProcessDescriptor
        var cpuPercent: Double
        var residentBytes: UInt64
        var processCount: Int
    }

    private let hostPort: mach_port_t
    private let pageSize: UInt64
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64
    private let coreCount: Int

    private var previousCPUTicks: CPUTicks?
    private var previousPerCoreTicks: [CPUTicks] = []
    private var networkRates = CounterRateCalculator()
    private var diskRates = CounterRateCalculator()
    private var previousProcesses: [ProcessKey: PreviousProcessValue] = [:]
    private var descriptorByProcessKey: [ProcessKey: ProcessDescriptor] = [:]
    private var descriptorCacheByPath: [String: ProcessDescriptor] = [:]
    private var pidPathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    private var lastProcessGroups: [ProcessGroupSample] = []
    private let humanizer = ProcessHumanizer()

    public init() {
        let host = mach_host_self()
        hostPort = host

        var rawPageSize: vm_size_t = 0
        if host_page_size(host, &rawPageSize) == KERN_SUCCESS, rawPageSize > 0 {
            pageSize = UInt64(rawPageSize)
        } else {
            pageSize = 16_384
        }

        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0, timebase.numer > 0 {
            timebaseNumer = UInt64(timebase.numer)
            timebaseDenom = UInt64(timebase.denom)
        } else {
            timebaseNumer = 1
            timebaseDenom = 1
        }

        coreCount = max(ProcessInfo.processInfo.activeProcessorCount, 1)
    }

    deinit {
        mach_port_deallocate(mach_task_self_, hostPort)
    }

    /// Converts Mach absolute time delta for a process into share of total Mac CPU (0...100%).
    public static func cpuSharePercent(
        deltaMachTicks: UInt64,
        elapsedSeconds: TimeInterval,
        timebaseNumer: UInt64,
        timebaseDenom: UInt64,
        coreCount: Int
    ) -> Double {
        guard elapsedSeconds > 0, timebaseDenom > 0, coreCount > 0 else { return 0 }
        let nanoseconds = Double(deltaMachTicks) * Double(timebaseNumer) / Double(timebaseDenom)
        let cpuSeconds = nanoseconds / 1_000_000_000.0
        let totalMacPercent = cpuSeconds / elapsedSeconds / Double(coreCount) * 100.0
        return min(max(totalMacPercent, 0), 100)
    }

    /// Computes Activity Monitor-aligned memory breakdown from Mach vm_statistics64 counters.
    public static func memoryBreakdown(
        totalBytes: UInt64,
        pageSize: UInt64,
        internalPages: UInt64,
        externalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        freePages: UInt64,
        inactivePages: UInt64,
        kernelPressureLevel: Int32?,
        swapUsedBytes: UInt64
    ) -> MemorySnapshot {
        let appPages = internalPages >= purgeablePages ? internalPages - purgeablePages : 0
        let app = appPages &* pageSize
        let wired = wiredPages &* pageSize
        let compressed = compressedPages &* pageSize
        let cached = (externalPages &+ purgeablePages) &* pageSize
        let used = min(app &+ wired &+ compressed, totalBytes)

        let pressure: MemoryPressureLevel
        if let kernelPressureLevel, kernelPressureLevel > 0 {
            if kernelPressureLevel >= 4 {
                pressure = .critical
            } else if kernelPressureLevel >= 2 {
                pressure = .warning
            } else {
                pressure = .normal
            }
        } else {
            let reclaimable = min((freePages &+ inactivePages &+ purgeablePages) &* pageSize, totalBytes)
            let availableFraction = totalBytes > 0 ? Double(reclaimable) / Double(totalBytes) : 1
            if availableFraction < 0.075 {
                pressure = .critical
            } else if availableFraction < 0.15 {
                pressure = .warning
            } else {
                pressure = .normal
            }
        }

        return MemorySnapshot(
            totalBytes: totalBytes,
            usedBytes: used,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: cached,
            swapUsedBytes: swapUsedBytes,
            pressure: pressure
        )
    }

    public func sample(includeProcesses: Bool) -> SystemSnapshot {
        let date = Date()
        let timestamp = date.timeIntervalSince1970
        let (cpu, perCore) = sampleCPUWithCores()
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
            coreCount: max(perCore.count, coreCount),
            perCoreCPU: perCore,
            memory: memory,
            network: network,
            disk: disk,
            thermalState: thermalState(),
            processes: lastProcessGroups
        )
    }

    private func sampleCPUWithCores() -> (total: Double, perCore: [Double]) {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        let kr = host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
        guard kr == KERN_SUCCESS, let cpuInfo, numCPUs > 0 else {
            return (sampleHostCPULegacy(), [])
        }
        defer {
            let size = vm_size_t(Int(numCPUInfo) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }

        let count = Int(numCPUs)
        let stateCount = Int(CPU_STATE_MAX)
        guard Int(numCPUInfo) >= count * stateCount else {
            return (sampleHostCPULegacy(), [])
        }

        var currentCores: [CPUTicks] = []
        currentCores.reserveCapacity(count)
        for index in 0..<count {
            let base = index * stateCount
            currentCores.append(
                CPUTicks(
                    user: UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)])),
                    system: UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)])),
                    idle: UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)])),
                    nice: UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)]))
                )
            )
        }

        defer { previousPerCoreTicks = currentCores }
        guard previousPerCoreTicks.count == count else {
            return (0, Array(repeating: 0, count: count))
        }

        var perCorePercentages: [Double] = []
        perCorePercentages.reserveCapacity(count)
        var sumBusy: UInt64 = 0
        var sumTotal: UInt64 = 0

        for index in 0..<count {
            let current = currentCores[index]
            let previous = previousPerCoreTicks[index]
            let userDelta = current.user >= previous.user ? current.user - previous.user : 0
            let systemDelta = current.system >= previous.system ? current.system - previous.system : 0
            let idleDelta = current.idle >= previous.idle ? current.idle - previous.idle : 0
            let niceDelta = current.nice >= previous.nice ? current.nice - previous.nice : 0
            let busyDelta = userDelta &+ systemDelta &+ niceDelta
            let totalDelta = busyDelta &+ idleDelta
            sumBusy &+= busyDelta
            sumTotal &+= totalDelta
            if totalDelta > 0 {
                perCorePercentages.append(min(max(Double(busyDelta) / Double(totalDelta) * 100.0, 0), 100))
            } else {
                perCorePercentages.append(0)
            }
        }

        let totalPercent = sumTotal > 0 ? min(max(Double(sumBusy) / Double(sumTotal) * 100.0, 0), 100) : 0
        return (totalPercent, perCorePercentages)
    }

    private func sampleHostCPULegacy() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, rebound, &count)
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
                host_statistics64(hostPort, HOST_VM_INFO64, rebound, &count)
            }
        }

        let total = ProcessInfo.processInfo.physicalMemory
        let swapUsed = sampleSwapUsed()
        let kernelPressure = sampleKernelMemoryPressure()
        guard result == KERN_SUCCESS else {
            return MemorySnapshot(
                totalBytes: total,
                usedBytes: 0,
                appBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                cachedBytes: 0,
                swapUsedBytes: swapUsed,
                pressure: kernelPressure.map { $0 >= 4 ? .critical : ($0 >= 2 ? .warning : .normal) } ?? .normal
            )
        }

        return Self.memoryBreakdown(
            totalBytes: total,
            pageSize: pageSize,
            internalPages: UInt64(statistics.internal_page_count),
            externalPages: UInt64(statistics.external_page_count),
            purgeablePages: UInt64(statistics.purgeable_count),
            wiredPages: UInt64(statistics.wire_count),
            compressedPages: UInt64(statistics.compressor_page_count),
            freePages: UInt64(statistics.free_count),
            inactivePages: UInt64(statistics.inactive_count),
            kernelPressureLevel: kernelPressure,
            swapUsedBytes: swapUsed
        )
    }

    private func sampleKernelMemoryPressure() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return level
    }

    private func sampleSwapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private func sampleNetworkTotals() -> (read: UInt64, write: UInt64) {
        if let totals64 = sampleNetworkTotals64() {
            return totals64
        }
        return sampleNetworkTotalsLegacy()
    }

    private func sampleNetworkTotals64() -> (read: UInt64, write: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else {
            return nil
        }

        var read: UInt64 = 0
        var write: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let header2 = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self).pointee
                    if (header2.ifm_flags & IFF_LOOPBACK) == 0 {
                        read &+= header2.ifm_data.ifi_ibytes
                        write &+= header2.ifm_data.ifi_obytes
                    }
                }
                offset += messageLength
            }
        }
        return (read, write)
    }

    private func sampleNetworkTotalsLegacy() -> (read: UInt64, write: UInt64) {
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
        currentValues.reserveCapacity(Int(count))
        var liveDescriptors: [ProcessKey: ProcessDescriptor] = [:]
        liveDescriptors.reserveCapacity(Int(count))
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

            let totalMachTicks: UInt64
            let memoryFootprintBytes: UInt64

            var rusage = rusage_info_v4()
            let rusageResult = withUnsafeMutablePointer(to: &rusage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
                }
            }
            if rusageResult == 0 {
                totalMachTicks = rusage.ri_user_time &+ rusage.ri_system_time
                memoryFootprintBytes = rusage.ri_phys_footprint
            } else {
                var taskInfo = proc_taskinfo()
                let taskBytes = proc_pidinfo(
                    pid,
                    PROC_PIDTASKINFO,
                    0,
                    &taskInfo,
                    Int32(MemoryLayout<proc_taskinfo>.size)
                )
                guard taskBytes == MemoryLayout<proc_taskinfo>.size else { continue }
                totalMachTicks = taskInfo.pti_total_user &+ taskInfo.pti_total_system
                memoryFootprintBytes = taskInfo.pti_resident_size
            }

            let key = ProcessKey(
                pid: pid,
                startSeconds: bsdInfo.pbi_start_tvsec,
                startMicroseconds: bsdInfo.pbi_start_tvusec
            )
            let current = PreviousProcessValue(totalMachTicks: totalMachTicks, timestamp: timestamp)
            currentValues[key] = current

            let cpuPercent: Double
            if
                let previous = previousProcesses[key],
                timestamp > previous.timestamp,
                totalMachTicks >= previous.totalMachTicks
            {
                let elapsed = timestamp - previous.timestamp
                cpuPercent = Self.cpuSharePercent(
                    deltaMachTicks: totalMachTicks - previous.totalMachTicks,
                    elapsedSeconds: elapsed,
                    timebaseNumer: timebaseNumer,
                    timebaseDenom: timebaseDenom,
                    coreCount: coreCount
                )
            } else {
                cpuPercent = 0
            }

            let descriptor: ProcessDescriptor
            if let cachedByKey = descriptorByProcessKey[key] {
                descriptor = cachedByKey
            } else {
                let name = processName(from: &bsdInfo)
                let path = processPath(pid: pid)
                let cacheKey = path.isEmpty ? name : path
                if let cachedByPath = descriptorCacheByPath[cacheKey] {
                    descriptor = cachedByPath
                } else {
                    descriptor = humanizer.describe(executableName: name, path: path)
                    descriptorCacheByPath[cacheKey] = descriptor
                }
            }
            liveDescriptors[key] = descriptor

            if var accumulator = groups[descriptor.groupKey] {
                accumulator.cpuPercent += max(cpuPercent, 0)
                accumulator.residentBytes &+= memoryFootprintBytes
                accumulator.processCount += 1
                if descriptor.explanationPriority > accumulator.descriptor.explanationPriority {
                    accumulator.descriptor = descriptor
                }
                groups[descriptor.groupKey] = accumulator
            } else {
                groups[descriptor.groupKey] = ProcessAccumulator(
                    descriptor: descriptor,
                    cpuPercent: max(cpuPercent, 0),
                    residentBytes: memoryFootprintBytes,
                    processCount: 1
                )
            }
        }

        previousProcesses = currentValues
        descriptorByProcessKey = liveDescriptors
        if descriptorCacheByPath.count > 2_000 {
            descriptorCacheByPath.removeAll(keepingCapacity: true)
        }

        let allSamples = groups.values.map { value in
            ProcessGroupSample(
                groupKey: value.descriptor.groupKey,
                displayName: value.descriptor.displayName,
                explanation: value.descriptor.explanation,
                category: value.descriptor.category,
                cpuPercent: min(value.cpuPercent, 100),
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
        let length = pidPathBuffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return 0 }
            base[0] = 0
            return proc_pidpath(pid, base, UInt32(pointer.count))
        }
        guard length > 0 else { return "" }
        return String(cString: pidPathBuffer)
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
