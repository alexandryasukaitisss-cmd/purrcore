import Foundation

public enum ProcessCategory: String, Codable, CaseIterable, Sendable {
    case browser
    case ai
    case development
    case communication
    case media
    case system
    case other

    public var localizedName: String {
        switch self {
        case .browser: "Браузеры"
        case .ai: "AI‑инструменты"
        case .development: "Разработка"
        case .communication: "Общение"
        case .media: "Медиа"
        case .system: "macOS"
        case .other: "Другое"
        }
    }
}

public enum MemoryPressureLevel: String, Codable, Sendable {
    case normal
    case warning
    case critical
}

public enum ThermalLevel: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public struct MemorySnapshot: Codable, Equatable, Sendable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pressure: MemoryPressureLevel

    public init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        appBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedBytes: UInt64,
        swapUsedBytes: UInt64,
        pressure: MemoryPressureLevel
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

public struct ThroughputSnapshot: Codable, Equatable, Sendable {
    public let downloadBytesPerSecond: Double
    public let uploadBytesPerSecond: Double

    public init(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) {
        self.downloadBytesPerSecond = max(downloadBytesPerSecond, 0)
        self.uploadBytesPerSecond = max(uploadBytesPerSecond, 0)
    }

    public static let zero = ThroughputSnapshot(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
}

public struct ProcessGroupSample: Identifiable, Codable, Equatable, Sendable {
    public var id: String { groupKey }

    public let groupKey: String
    public let displayName: String
    public let explanation: String
    public let category: ProcessCategory
    public let cpuPercent: Double
    public let residentBytes: UInt64
    public let processCount: Int

    public init(
        groupKey: String,
        displayName: String,
        explanation: String,
        category: ProcessCategory,
        cpuPercent: Double,
        residentBytes: UInt64,
        processCount: Int
    ) {
        self.groupKey = groupKey
        self.displayName = displayName
        self.explanation = explanation
        self.category = category
        self.cpuPercent = max(cpuPercent, 0)
        self.residentBytes = residentBytes
        self.processCount = max(processCount, 1)
    }
}

public struct SystemSnapshot: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let cpuPercent: Double
    public let memory: MemorySnapshot
    public let network: ThroughputSnapshot
    public let disk: ThroughputSnapshot
    public let thermalState: ThermalLevel
    public let processes: [ProcessGroupSample]

    public init(
        timestamp: Date,
        cpuPercent: Double,
        memory: MemorySnapshot,
        network: ThroughputSnapshot,
        disk: ThroughputSnapshot,
        thermalState: ThermalLevel,
        processes: [ProcessGroupSample]
    ) {
        self.timestamp = timestamp
        self.cpuPercent = min(max(cpuPercent, 0), 100)
        self.memory = memory
        self.network = network
        self.disk = disk
        self.thermalState = thermalState
        self.processes = processes
    }

    public static let empty = SystemSnapshot(
        timestamp: .now,
        cpuPercent: 0,
        memory: MemorySnapshot(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            usedBytes: 0,
            appBytes: 0,
            wiredBytes: 0,
            compressedBytes: 0,
            cachedBytes: 0,
            swapUsedBytes: 0,
            pressure: .normal
        ),
        network: .zero,
        disk: .zero,
        thermalState: .unknown,
        processes: []
    )
}

public struct HistoryPoint: Identifiable, Codable, Equatable, Sendable {
    public var id: TimeInterval { timestamp.timeIntervalSince1970 }

    public let timestamp: Date
    public let cpuPercent: Double
    public let memoryUsedBytes: UInt64
    public let networkDownloadBytesPerSecond: Double
    public let networkUploadBytesPerSecond: Double
    public let diskReadBytesPerSecond: Double
    public let diskWriteBytesPerSecond: Double

    public init(
        timestamp: Date,
        cpuPercent: Double,
        memoryUsedBytes: UInt64,
        networkDownloadBytesPerSecond: Double,
        networkUploadBytesPerSecond: Double,
        diskReadBytesPerSecond: Double,
        diskWriteBytesPerSecond: Double
    ) {
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.networkDownloadBytesPerSecond = networkDownloadBytesPerSecond
        self.networkUploadBytesPerSecond = networkUploadBytesPerSecond
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
    }

    public init(snapshot: SystemSnapshot) {
        self.init(
            timestamp: snapshot.timestamp,
            cpuPercent: snapshot.cpuPercent,
            memoryUsedBytes: snapshot.memory.usedBytes,
            networkDownloadBytesPerSecond: snapshot.network.downloadBytesPerSecond,
            networkUploadBytesPerSecond: snapshot.network.uploadBytesPerSecond,
            diskReadBytesPerSecond: snapshot.disk.downloadBytesPerSecond,
            diskWriteBytesPerSecond: snapshot.disk.uploadBytesPerSecond
        )
    }

    /// Merges stored and live readings, preferring live values at matching timestamps,
    /// then averages interior readings into a bounded, ordered series.
    public static func mergedAndDownsampled(
        stored: [HistoryPoint],
        live: [HistoryPoint],
        since: Date,
        until: Date,
        maximumCount: Int
    ) -> [HistoryPoint] {
        guard until >= since else { return [] }

        let limit = max(maximumCount, 1)
        let firstLiveTimestamp = live.map(\.timestamp).filter { $0 >= since && $0 <= until }.min()
        var pointsByTimestamp: [TimeInterval: HistoryPoint] = [:]
        for point in stored where point.timestamp >= since && point.timestamp <= until
            && (firstLiveTimestamp.map { point.timestamp < $0 } ?? true) {
            pointsByTimestamp[point.timestamp.timeIntervalSince1970] = point
        }
        for point in live where point.timestamp >= since && point.timestamp <= until {
            pointsByTimestamp[point.timestamp.timeIntervalSince1970] = point
        }

        let points = pointsByTimestamp.keys.sorted().compactMap { pointsByTimestamp[$0] }
        guard points.count > limit else { return points }
        guard limit > 1 else { return [points[points.count - 1]] }

        let interiorCount = points.count - 2
        let bucketCount = limit - 2
        var result = [points[0]]
        result.reserveCapacity(limit)

        if bucketCount > 0 {
            for bucket in 0..<bucketCount {
                let start = 1 + bucket * interiorCount / bucketCount
                let end = 1 + (bucket + 1) * interiorCount / bucketCount
                let readings = points[start..<end]
                let count = Double(readings.count)
                func average(_ value: (HistoryPoint) -> Double) -> Double {
                    readings.reduce(0) { $0 + value($1) } / count
                }
                result.append(
                    HistoryPoint(
                        timestamp: Date(timeIntervalSince1970: average { $0.timestamp.timeIntervalSince1970 }),
                        cpuPercent: average(\.cpuPercent),
                        memoryUsedBytes: UInt64(max(average { Double($0.memoryUsedBytes) }, 0)),
                        networkDownloadBytesPerSecond: average(\.networkDownloadBytesPerSecond),
                        networkUploadBytesPerSecond: average(\.networkUploadBytesPerSecond),
                        diskReadBytesPerSecond: average(\.diskReadBytesPerSecond),
                        diskWriteBytesPerSecond: average(\.diskWriteBytesPerSecond)
                    )
                )
            }
        }

        result.append(points[points.count - 1])
        return result
    }
}

public enum TaskEventKind: String, Codable, Sendable {
    case begin
    case end
}

public struct TaskMarker: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let source: String
    public let taskID: String
    public let label: String
    public let kind: TaskEventKind
    public let timestamp: Date

    public init(id: String, source: String, taskID: String, label: String, kind: TaskEventKind, timestamp: Date) {
        self.id = id
        self.source = source
        self.taskID = taskID
        self.label = label
        self.kind = kind
        self.timestamp = timestamp
    }
}

public struct ProcessDescriptor: Equatable, Sendable {
    public let groupKey: String
    public let displayName: String
    public let explanation: String
    public let category: ProcessCategory

    public init(groupKey: String, displayName: String, explanation: String, category: ProcessCategory) {
        self.groupKey = groupKey
        self.displayName = displayName
        self.explanation = explanation
        self.category = category
    }
}
