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
        var representativePID: Int32?
        var representativePriority: Int
        var representativeWeight: Double
        var bundlePath: String?
        var canTerminate: Bool
    }

    private let hostPort: mach_port_t
    private let pageSize: UInt64
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64
    private let coreCount: Int
    private let coreClusters: [CoreClusterKind]
    private let currentUID: uid_t
    private let selfPID: Int32

    private var previousCPUTicks: CPUTicks?
    private var previousPerCoreTicks: [CPUTicks] = []
    private var networkRates = CounterRateCalculator()
    private var diskRates = CounterRateCalculator()
    private var previousProcesses: [ProcessKey: PreviousProcessValue] = [:]
    private var descriptorByProcessKey: [ProcessKey: ProcessDescriptor] = [:]
    private var pathByProcessKey: [ProcessKey: String] = [:]
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

        let detectedCores = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        coreCount = detectedCores
        coreClusters = Self.detectCoreClusters(expectedCoreCount: detectedCores)
        currentUID = getuid()
        selfPID = getpid()
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

    /// Extracts GPU utilization percentage (0...100) from an IOAccelerator PerformanceStatistics dictionary.
    public static func gpuUtilizationPercent(from statistics: [String: Any]) -> Double? {
        if let direct = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue {
            return min(max(direct, 0), 100)
        }
        let renderer = (statistics["Renderer Utilization %"] as? NSNumber)?.doubleValue
        let tiler = (statistics["Tiler Utilization %"] as? NSNumber)?.doubleValue
        if renderer != nil || tiler != nil {
            return min(max(max(renderer ?? 0, tiler ?? 0), 0), 100)
        }
        if let rawCore = (statistics["GPU Core Utilization"] as? NSNumber)?.doubleValue {
            let scaled = rawCore > 100 ? (rawCore / 10_000_000.0) : rawCore
            return min(max(scaled, 0), 100)
        }
        return nil
    }

    /// Extracts the outermost `.app` bundle path from an executable path (so nested Helpers resolve to the parent `.app`).
    public static func outermostAppBundlePath(from executablePath: String) -> String? {
        guard !executablePath.isEmpty,
              let range = executablePath.range(of: ".app/")
        else {
            return nil
        }
        return String(executablePath[..<range.upperBound].dropLast())
    }

    public static func isPrimaryAppExecutable(path: String, bundlePath: String?) -> Bool {
        guard let bundlePath, !path.isEmpty else { return false }
        let prefix = bundlePath + "/Contents/MacOS/"
        guard path.hasPrefix(prefix) else { return false }
        let remainder = path.dropFirst(prefix.count)
        return !remainder.isEmpty && !remainder.contains("/")
    }

    public static func isTerminableUserProcess(
        pid: Int32,
        uid: uid_t,
        currentUID: uid_t,
        selfPID: Int32,
        category: ProcessCategory,
        executablePath: String
    ) -> Bool {
        guard pid > 1, pid != selfPID, uid == currentUID, category != .system else {
            return false
        }
        let protectedPrefixes = [
            "/System/",
            "/usr/libexec/",
            "/sbin/",
            "/usr/sbin/",
            "/Library/Apple/"
        ]
        if protectedPrefixes.contains(where: { executablePath.hasPrefix($0) }) {
            return false
        }
        return true
    }

    public static func detectCoreClusters(expectedCoreCount: Int) -> [CoreClusterKind] {
        if let fromRegistry = detectCoreClustersFromIORegistry(expectedCoreCount: expectedCoreCount) {
            return fromRegistry
        }
        return detectCoreClustersFromSysctl(expectedCoreCount: expectedCoreCount)
    }

    private static func detectCoreClustersFromIORegistry(expectedCoreCount: Int) -> [CoreClusterKind]? {
        guard let matching = IOServiceNameMatching("cpus") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var byIndex: [Int: CoreClusterKind] = [:]
        var cpusEntry = IOIteratorNext(iterator)
        while cpusEntry != 0 {
            var childIter: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpusEntry, kIODeviceTreePlane, &childIter) == KERN_SUCCESS {
                var child = IOIteratorNext(childIter)
                while child != 0 {
                    if let idProp = IORegistryEntryCreateCFProperty(child, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                       let typeProp = IORegistryEntryCreateCFProperty(child, "cluster-type" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                       let logicalID = parseRegistryInt(idProp),
                       let kind = parseClusterKind(typeProp)
                    {
                        byIndex[logicalID] = kind
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(childIter)
                }
                IOObjectRelease(childIter)
            }
            IOObjectRelease(cpusEntry)
            cpusEntry = IOIteratorNext(iterator)
        }

        guard byIndex.count == expectedCoreCount else { return nil }
        var ordered: [CoreClusterKind] = []
        ordered.reserveCapacity(expectedCoreCount)
        for idx in 0..<expectedCoreCount {
            guard let kind = byIndex[idx] else { return nil }
            ordered.append(kind)
        }
        guard ordered.contains(.efficiency) && ordered.contains(.performance) else {
            return nil
        }
        return ordered
    }

    private static func parseRegistryInt(_ value: CFTypeRef) -> Int? {
        if let num = value as? NSNumber {
            return num.intValue
        }
        if let data = value as? Data, data.count >= 4 {
            let raw = data.withUnsafeBytes { ptr in
                ptr.loadUnaligned(as: UInt32.self)
            }
            return Int(UInt32(littleEndian: raw))
        }
        return nil
    }

    private static func parseClusterKind(_ value: CFTypeRef) -> CoreClusterKind? {
        let str: String?
        if let s = value as? String {
            str = s
        } else if let data = value as? Data {
            str = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        } else {
            str = nil
        }
        guard let trimmed = str?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            return nil
        }
        if trimmed.hasPrefix("E") { return .efficiency }
        if trimmed.hasPrefix("P") { return .performance }
        return nil
    }

    private static func detectCoreClustersFromSysctl(expectedCoreCount: Int) -> [CoreClusterKind] {
        guard let levels = sysctlInt("hw.nperflevels"), levels >= 2 else { return [] }
        var effCount = 0
        var perfCount = 0
        for level in 0..<levels {
            let count = sysctlInt("hw.perflevel\(level).logicalcpu") ?? 0
            let name = (sysctlString("hw.perflevel\(level).name") ?? "").lowercased()
            if name.contains("eff") {
                effCount += count
            } else if name.contains("perf") {
                perfCount += count
            }
        }
        guard effCount > 0, perfCount > 0, effCount + perfCount == expectedCoreCount else {
            return []
        }
        return Array(repeating: .efficiency, count: effCount) + Array(repeating: .performance, count: perfCount)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    public func sample(includeProcesses: Bool) -> SystemSnapshot {
        let date = Date()
        let timestamp = date.timeIntervalSince1970
        let (cpu, perCore) = sampleCPUWithCores()
        let gpu = sampleGPUPercent()
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

        let matchedClusters = coreClusters.count == perCore.count ? coreClusters : []
        return SystemSnapshot(
            timestamp: date,
            cpuPercent: cpu,
            coreCount: max(perCore.count, coreCount),
            perCoreCPU: perCore,
            coreClusters: matchedClusters,
            gpuPercent: gpu,
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

    private func sampleGPUPercent() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var maxUtilization: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any],
               let util = Self.gpuUtilizationPercent(from: stats)
            {
                maxUtilization = max(maxUtilization ?? 0, util)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return maxUtilization
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
        var livePaths: [ProcessKey: String] = [:]
        livePaths.reserveCapacity(Int(count))
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
            let resolvedPath: String
            if let cachedByKey = descriptorByProcessKey[key], let cachedPath = pathByProcessKey[key] {
                descriptor = cachedByKey
                resolvedPath = cachedPath
            } else {
                let name = processName(from: &bsdInfo)
                let path = processPath(pid: pid)
                resolvedPath = path
                let cacheKey = path.isEmpty ? name : path
                if let cachedByPath = descriptorCacheByPath[cacheKey] {
                    descriptor = cachedByPath
                } else {
                    descriptor = humanizer.describe(executableName: name, path: path)
                    descriptorCacheByPath[cacheKey] = descriptor
                }
            }
            liveDescriptors[key] = descriptor
            livePaths[key] = resolvedPath

            let appBundle = Self.outermostAppBundlePath(from: resolvedPath)
            let isMainAppBinary = Self.isPrimaryAppExecutable(path: resolvedPath, bundlePath: appBundle)
            let repPriority = isMainAppBinary ? 2 : (appBundle != nil ? 1 : 0)
            let repWeight = max(cpuPercent, 0) * 1_000_000_000.0 + Double(memoryFootprintBytes)
            let terminable = Self.isTerminableUserProcess(
                pid: pid,
                uid: bsdInfo.pbi_uid,
                currentUID: currentUID,
                selfPID: selfPID,
                category: descriptor.category,
                executablePath: resolvedPath
            )

            if var accumulator = groups[descriptor.groupKey] {
                accumulator.cpuPercent += max(cpuPercent, 0)
                accumulator.residentBytes &+= memoryFootprintBytes
                accumulator.processCount += 1
                if descriptor.explanationPriority > accumulator.descriptor.explanationPriority {
                    accumulator.descriptor = descriptor
                }
                if accumulator.bundlePath == nil, let appBundle {
                    accumulator.bundlePath = appBundle
                }
                if terminable && (repPriority > accumulator.representativePriority
                    || (repPriority == accumulator.representativePriority && repWeight > accumulator.representativeWeight))
                {
                    accumulator.representativePID = pid
                    accumulator.representativePriority = repPriority
                    accumulator.representativeWeight = repWeight
                    accumulator.canTerminate = true
                    if let appBundle {
                        accumulator.bundlePath = appBundle
                    }
                }
                groups[descriptor.groupKey] = accumulator
            } else {
                groups[descriptor.groupKey] = ProcessAccumulator(
                    descriptor: descriptor,
                    cpuPercent: max(cpuPercent, 0),
                    residentBytes: memoryFootprintBytes,
                    processCount: 1,
                    representativePID: terminable ? pid : nil,
                    representativePriority: terminable ? repPriority : -1,
                    representativeWeight: terminable ? repWeight : -1,
                    bundlePath: appBundle,
                    canTerminate: terminable
                )
            }
        }

        previousProcesses = currentValues
        descriptorByProcessKey = liveDescriptors
        pathByProcessKey = livePaths
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
                processCount: value.processCount,
                representativePID: value.representativePID,
                bundlePath: value.bundlePath,
                canTerminate: value.canTerminate && value.representativePID != nil
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
