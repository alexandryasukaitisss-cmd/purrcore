import Foundation

public enum SmartAlertKind: String, CaseIterable, Hashable, Sendable {
    case criticalMemory
    case highThermal
    case sustainedHighCPU
    case lowDiskSpace
}

public struct SmartAlertEvent: Equatable, Sendable {
    public let kind: SmartAlertKind
    public let topProcessName: String?
    public let topProcessMemoryBytes: UInt64?
    public let topProcessCPUPercent: Double?
    public let freeDiskBytes: UInt64?

    public init(
        kind: SmartAlertKind,
        topProcessName: String? = nil,
        topProcessMemoryBytes: UInt64? = nil,
        topProcessCPUPercent: Double? = nil,
        freeDiskBytes: UInt64? = nil
    ) {
        self.kind = kind
        self.topProcessName = topProcessName
        self.topProcessMemoryBytes = topProcessMemoryBytes
        self.topProcessCPUPercent = topProcessCPUPercent
        self.freeDiskBytes = freeDiskBytes
    }
}

public struct SmartAlertTracker: Sendable {
    public static let highCPUThresholdPercent: Double = 85.0
    public static let highCPUDurationsSeconds: TimeInterval = 180.0
    public static let lowDiskThresholdBytes: UInt64 = 15 * 1_073_741_824
    public static let defaultCooldownSeconds: TimeInterval = 1_800.0

    public var cooldownSeconds: TimeInterval
    private var highCPUSince: Date?
    private var lastFiredAt: [SmartAlertKind: Date] = [:]

    public init(cooldownSeconds: TimeInterval = SmartAlertTracker.defaultCooldownSeconds) {
        self.cooldownSeconds = cooldownSeconds
    }

    public mutating func reset() {
        highCPUSince = nil
        lastFiredAt.removeAll()
    }

    public mutating func evaluate(
        snapshot: SystemSnapshot,
        ssd: SSDSnapshot?,
        now: Date
    ) -> [SmartAlertEvent] {
        var events: [SmartAlertEvent] = []

        // 1. Critical memory pressure
        if snapshot.memory.pressure == .critical, canFire(.criticalMemory, at: now) {
            let leader = snapshot.processes.max(by: { $0.residentBytes < $1.residentBytes })
            lastFiredAt[.criticalMemory] = now
            events.append(
                SmartAlertEvent(
                    kind: .criticalMemory,
                    topProcessName: leader?.displayName,
                    topProcessMemoryBytes: leader?.residentBytes
                )
            )
        }

        // 2. Serious / critical thermal throttling
        if snapshot.thermalState == .serious || snapshot.thermalState == .critical,
           canFire(.highThermal, at: now)
        {
            let leader = snapshot.processes.max(by: { $0.cpuPercent < $1.cpuPercent })
            lastFiredAt[.highThermal] = now
            events.append(
                SmartAlertEvent(
                    kind: .highThermal,
                    topProcessName: leader?.displayName,
                    topProcessCPUPercent: leader?.cpuPercent
                )
            )
        }

        // 3. Sustained high CPU (>= 85% for 3 continuous minutes)
        if snapshot.cpuPercent >= Self.highCPUThresholdPercent {
            let start = highCPUSince ?? now
            highCPUSince = start
            if now.timeIntervalSince(start) >= Self.highCPUDurationsSeconds,
               canFire(.sustainedHighCPU, at: now)
            {
                let leader = snapshot.processes.max(by: { $0.cpuPercent < $1.cpuPercent })
                lastFiredAt[.sustainedHighCPU] = now
                events.append(
                    SmartAlertEvent(
                        kind: .sustainedHighCPU,
                        topProcessName: leader?.displayName,
                        topProcessCPUPercent: leader?.cpuPercent
                    )
                )
            }
        } else {
            highCPUSince = nil
        }

        // 4. Low SSD free space (< 15 GiB)
        if let ssd, ssd.totalBytes > 0, ssd.freeBytes < Self.lowDiskThresholdBytes,
           canFire(.lowDiskSpace, at: now)
        {
            lastFiredAt[.lowDiskSpace] = now
            events.append(
                SmartAlertEvent(
                    kind: .lowDiskSpace,
                    freeDiskBytes: ssd.freeBytes
                )
            )
        }

        return events
    }

    private func canFire(_ kind: SmartAlertKind, at now: Date) -> Bool {
        guard let previous = lastFiredAt[kind] else { return true }
        return now.timeIntervalSince(previous) >= cooldownSeconds
    }
}
