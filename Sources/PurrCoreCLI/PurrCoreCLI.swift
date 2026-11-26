import Darwin
import Foundation
import PurrCoreCore

private enum CLIError: Error, LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): message
        }
    }
}

private struct MarkerOptions {
    var source = "external"
    var taskID = ""
    var label = ""
}

private struct LiveMemory: Encodable {
    var usedBytes: UInt64
    var totalBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var cachedBytes: UInt64
    var swapUsedBytes: UInt64
    var pressure: String

    enum CodingKeys: String, CodingKey {
        case usedBytes = "used_bytes"
        case totalBytes = "total_bytes"
        case appBytes = "app_bytes"
        case wiredBytes = "wired_bytes"
        case compressedBytes = "compressed_bytes"
        case cachedBytes = "cached_bytes"
        case swapUsedBytes = "swap_used_bytes"
        case pressure
    }
}

private struct LiveNetworkBps: Encodable {
    var download: Double
    var upload: Double
}

private struct LiveDiskBps: Encodable {
    var read: Double
    var write: Double
}

private struct LiveProcess: Encodable {
    var name: String
    var explanation: String
    var category: String
    var cpuPercent: Double
    var equivalentCores: Double
    var residentBytes: UInt64
    var processCount: Int

    enum CodingKeys: String, CodingKey {
        case name
        case explanation
        case category
        case cpuPercent = "cpu_percent"
        case equivalentCores = "equivalent_cores"
        case residentBytes = "resident_bytes"
        case processCount = "process_count"
    }
}

private struct LiveReport: Encodable {
    var timestamp: Date
    var cpuPercent: Double
    var gpuPercent: Double?
    var coreCount: Int
    var busyCores: Int
    var perCoreCPU: [Double]
    var efficiencyCoreCPU: [Double]
    var performanceCoreCPU: [Double]
    var memory: LiveMemory
    var networkBps: LiveNetworkBps
    var diskBps: LiveDiskBps
    var thermal: String
    var topProcesses: [LiveProcess]

    enum CodingKeys: String, CodingKey {
        case timestamp
        case cpuPercent = "cpu_percent"
        case gpuPercent = "gpu_percent"
        case coreCount = "core_count"
        case busyCores = "busy_cores"
        case perCoreCPU = "per_core_cpu"
        case efficiencyCoreCPU = "efficiency_core_cpu"
        case performanceCoreCPU = "performance_core_cpu"
        case memory
        case networkBps = "network_bps"
        case diskBps = "disk_bps"
        case thermal
        case topProcesses = "top_processes"
    }
}

private struct ReportAvgMax: Encodable {
    var avg: Double
    var max: Double
}

private struct ReportNetworkBps: Encodable {
    var downloadAvg: Double
    var uploadAvg: Double

    enum CodingKeys: String, CodingKey {
        case downloadAvg = "download_avg"
        case uploadAvg = "upload_avg"
    }
}

private struct ReportDiskBps: Encodable {
    var readAvg: Double
    var writeAvg: Double

    enum CodingKeys: String, CodingKey {
        case readAvg = "read_avg"
        case writeAvg = "write_avg"
    }
}

private struct TaskLoadReport: Encodable {
    var durationSeconds: Double
    var samples: Int
    var cpuPercent: ReportAvgMax
    var memoryUsedBytes: ReportAvgMax
    var swapUsedBytes: ReportAvgMax
    var networkBps: ReportNetworkBps
    var diskBps: ReportDiskBps

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case samples
        case cpuPercent = "cpu_percent"
        case memoryUsedBytes = "memory_used_bytes"
        case swapUsedBytes = "swap_used_bytes"
        case networkBps = "network_bps"
        case diskBps = "disk_bps"
    }
}

private struct SSDCLIReport: Encodable {
    var internalSSD: SSDHealthSnapshot?
    var internalError: String?
    var externalSSDs: [ExternalSSDHealthReport]
    var externalError: String?

    enum CodingKeys: String, CodingKey {
        case internalSSD = "internal"
        case internalError = "internal_error"
        case externalSSDs = "external"
        case externalError = "external_error"
    }
}

@main
struct PurrCoreCLI {
    static func main() async {
        do {
            let status = try await run(Array(CommandLine.arguments.dropFirst()))
            exit(status)
        } catch {
            FileHandle.standardError.write(Data("purrcorectl: \(error.localizedDescription)\n".utf8))
            printUsage()
            exit(2)
        }
    }

    private static func openStore() throws -> HistoryStore {
        try HistoryStore(url: RuntimePaths.historyDatabaseURL())
    }

    private static func run(_ arguments: [String]) async throws -> Int32 {
        guard let command = arguments.first else { throw CLIError.usage("не указана команда") }

        switch command {
        case "live":
            let sampler = SystemSampler()
            _ = await sampler.sample(includeProcesses: true)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let snapshot = await sampler.sample(includeProcesses: true)
            try printJSON(Self.liveReport(from: snapshot))
            return 0

        case "ssd":
            let reader = SSDHealthReader()
            var internalSSD: SSDHealthSnapshot?
            var internalError: String?
            do {
                internalSSD = try reader.read()
            } catch {
                internalError = error.localizedDescription
            }
            var externalSSDs: [ExternalSSDHealthReport] = []
            var externalError: String?
            do {
                externalSSDs = try reader.readExternalDisks()
            } catch {
                externalError = error.localizedDescription
            }
            try printJSON(SSDCLIReport(
                internalSSD: internalSSD,
                internalError: internalError,
                externalSSDs: externalSSDs,
                externalError: externalError
            ))
            return 0

        case "history":
            let store = try openStore()
            let (rangeSeconds, maxPoints) = try parseHistoryOptions(Array(arguments.dropFirst()))
            let now = Date()
            let since = now.addingTimeInterval(-rangeSeconds)
            let points = try await store.loadSystemHistory(since: since, until: now, maxPoints: maxPoints)
            try printJSON(points)
            return 0

        case "top":
            let store = try openStore()
            let (sortBy, rangeSeconds, limit) = try parseTopOptions(Array(arguments.dropFirst()))
            let now = Date()
            let since = now.addingTimeInterval(-rangeSeconds)
            let groups = try await store.loadTopProcessGroups(since: since, until: now, sortBy: sortBy, limit: limit)
            try printJSON(groups)
            return 0

        case "usage":
            let store = try openStore()
            let now = Date()
            let calendar = Calendar.autoupdatingCurrent
            let since = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
                ?? now.addingTimeInterval(-6 * 86_400)
            let report = try await store.loadUsageReport(since: since, until: now, calendar: calendar)
            try printJSON(report)
            return 0

        case "task":
            let store = try openStore()
            guard arguments.count >= 2, let kind = TaskEventKind(rawValue: arguments[1]) else {
                throw CLIError.usage("ожидалось: task begin|end")
            }
            let options = try parseMarkerOptions(Array(arguments.dropFirst(2)))
            try await store.addTaskMarker(marker(kind: kind, options: options))
            print("\(kind.rawValue) \(options.taskID) \(options.label)")
            if kind == .end {
                await printTaskReport(store: store, taskID: options.taskID)
            }
            return 0

        case "run":
            let store = try openStore()
            guard let separator = arguments.firstIndex(of: "--") else {
                throw CLIError.usage("для run нужен разделитель -- перед командой")
            }
            let options = try parseMarkerOptions(Array(arguments[1..<separator]))
            let childArguments = Array(arguments[(separator + 1)...])
            guard !childArguments.isEmpty else { throw CLIError.usage("после -- нет команды") }

            try await store.addTaskMarker(marker(kind: .begin, options: options))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = childArguments
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                try? await store.addTaskMarker(marker(kind: .end, options: options))
                await printTaskReport(store: store, taskID: options.taskID)
                throw error
            }
            try await store.addTaskMarker(marker(kind: .end, options: options))
            await printTaskReport(store: store, taskID: options.taskID)
            return process.terminationStatus

        case "purge":
            let store = try openStore()
            try await store.purge(olderThan: Date().addingTimeInterval(-604_800))
            print("история старше 7 дней удалена")
            return 0

        case "status":
            let store = try openStore()
            let url = try RuntimePaths.historyDatabaseURL()
            let size = await store.databaseSizeBytes()
            print("database=\(url.path)")
            print("bytes=\(size)")
            return 0

        default:
            throw CLIError.usage("неизвестная команда: \(command)")
        }
    }

    private static func parseRange(_ raw: String) throws -> TimeInterval {
        switch raw.lowercased() {
        case "1h", "hour": return 3_600
        case "24h", "1d", "day": return 86_400
        case "7d", "week": return 604_800
        default:
            throw CLIError.usage("неподдерживаемый период: \(raw) (ожидалось 1h, 24h или 7d)")
        }
    }

    private static func parseHistoryOptions(_ arguments: [String]) throws -> (TimeInterval, Int) {
        var range: TimeInterval = 3_600
        var points = 240
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw CLIError.usage("для \(arguments[index]) не указано значение")
            }
            switch arguments[index] {
            case "--range":
                range = try parseRange(arguments[index + 1])
            case "--points":
                guard let parsed = Int(arguments[index + 1]), parsed > 0 else {
                    throw CLIError.usage("некорректное число точек: \(arguments[index + 1])")
                }
                points = min(parsed, 4_096)
            default:
                throw CLIError.usage("неизвестный параметр: \(arguments[index])")
            }
            index += 2
        }
        return (range, points)
    }

    private static func parseTopOptions(_ arguments: [String]) throws -> (ProcessHistorySort, TimeInterval, Int) {
        var sortBy: ProcessHistorySort = .cpu
        var range: TimeInterval = 3_600
        var limit = 10
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw CLIError.usage("для \(arguments[index]) не указано значение")
            }
            switch arguments[index] {
            case "--by":
                guard let parsed = ProcessHistorySort(rawValue: arguments[index + 1].lowercased()) else {
                    throw CLIError.usage("неподдерживаемая сортировка: \(arguments[index + 1]) (ожидалось cpu или memory)")
                }
                sortBy = parsed
            case "--range":
                range = try parseRange(arguments[index + 1])
            case "--limit":
                guard let parsed = Int(arguments[index + 1]), parsed > 0 else {
                    throw CLIError.usage("некорректный лимит: \(arguments[index + 1])")
                }
                limit = min(parsed, 100)
            default:
                throw CLIError.usage("неизвестный параметр: \(arguments[index])")
            }
            index += 2
        }
        return (sortBy, range, limit)
    }

    private static func parseMarkerOptions(_ arguments: [String]) throws -> MarkerOptions {
        var options = MarkerOptions()
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw CLIError.usage("для \(arguments[index]) не указано значение")
            }
            switch arguments[index] {
            case "--source": options.source = arguments[index + 1]
            case "--task-id", "--id": options.taskID = arguments[index + 1]
            case "--label": options.label = arguments[index + 1]
            default: throw CLIError.usage("неизвестный параметр: \(arguments[index])")
            }
            index += 2
        }

        if options.taskID.isEmpty { options.taskID = UUID().uuidString }
        if options.label.isEmpty { options.label = options.taskID }
        return options
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let data = try Self.jsonEncoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func liveReport(from snapshot: SystemSnapshot) -> LiveReport {
        LiveReport(
            timestamp: snapshot.timestamp,
            cpuPercent: snapshot.cpuPercent,
            gpuPercent: snapshot.gpuPercent,
            coreCount: snapshot.coreCount,
            busyCores: snapshot.busyCoreCount(),
            perCoreCPU: snapshot.perCoreCPU,
            efficiencyCoreCPU: snapshot.efficiencyCoreLoads,
            performanceCoreCPU: snapshot.performanceCoreLoads,
            memory: LiveMemory(
                usedBytes: snapshot.memory.usedBytes,
                totalBytes: snapshot.memory.totalBytes,
                appBytes: snapshot.memory.appBytes,
                wiredBytes: snapshot.memory.wiredBytes,
                compressedBytes: snapshot.memory.compressedBytes,
                cachedBytes: snapshot.memory.cachedBytes,
                swapUsedBytes: snapshot.memory.swapUsedBytes,
                pressure: snapshot.memory.pressure.rawValue
            ),
            networkBps: LiveNetworkBps(
                download: snapshot.network.downloadBytesPerSecond,
                upload: snapshot.network.uploadBytesPerSecond
            ),
            diskBps: LiveDiskBps(
                read: snapshot.disk.downloadBytesPerSecond,
                write: snapshot.disk.uploadBytesPerSecond
            ),
            thermal: snapshot.thermalState.rawValue,
            topProcesses: snapshot.processes
                .sorted { $0.cpuPercent > $1.cpuPercent }
                .prefix(8)
                .map { sample in
                    LiveProcess(
                        name: sample.displayName,
                        explanation: sample.explanation,
                        category: sample.category.rawValue,
                        cpuPercent: sample.cpuPercent,
                        equivalentCores: sample.equivalentCores(totalCores: snapshot.coreCount),
                        residentBytes: sample.residentBytes,
                        processCount: sample.processCount
                    )
                }
        )
    }

    private static func printTaskReport(store: HistoryStore, taskID: String) async {
        func avgMax(_ values: [Double]) -> ReportAvgMax {
            guard let max = values.max() else { return ReportAvgMax(avg: 0, max: 0) }
            return ReportAvgMax(avg: values.reduce(0, +) / Double(values.count), max: max)
        }
        func average(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }

        guard
            let begin = try? await store.loadTaskMarkers(
                since: Date(timeIntervalSinceNow: -604_800),
                until: .now
            )
            .filter({ $0.taskID == taskID && $0.kind == .begin })
            .last
        else { return }

        let end = Date()
        guard
            let points = try? await store.loadSystemHistory(
                since: begin.timestamp,
                until: end,
                maxPoints: 4096
            )
        else { return }

        let report = TaskLoadReport(
            durationSeconds: end.timeIntervalSince(begin.timestamp),
            samples: points.count,
            cpuPercent: avgMax(points.map(\.cpuPercent)),
            memoryUsedBytes: avgMax(points.map { Double($0.memoryUsedBytes) }),
            swapUsedBytes: avgMax(points.map { Double($0.swapUsedBytes) }),
            networkBps: ReportNetworkBps(
                downloadAvg: average(points.map(\.networkDownloadBytesPerSecond)),
                uploadAvg: average(points.map(\.networkUploadBytesPerSecond))
            ),
            diskBps: ReportDiskBps(
                readAvg: average(points.map(\.diskReadBytesPerSecond)),
                writeAvg: average(points.map(\.diskWriteBytesPerSecond))
            )
        )
        try? printJSON(report)
    }

    private static func marker(kind: TaskEventKind, options: MarkerOptions) -> TaskMarker {
        TaskMarker(
            id: UUID().uuidString,
            source: options.source,
            taskID: options.taskID,
            label: options.label,
            kind: kind,
            timestamp: Date()
        )
    }

    private static func printUsage() {
        let usage = """
        Использование:
          purrcorectl live
          purrcorectl history [--range 1h|24h|7d] [--points N]
          purrcorectl top [--by cpu|memory] [--range 1h|24h|7d] [--limit N]
          purrcorectl usage
          purrcorectl ssd
          purrcorectl task begin --source mempalace --task-id ID --label "Название"
          purrcorectl task end   --source mempalace --task-id ID --label "Название"
          purrcorectl run --source mempalace --task-id ID --label "Название" -- команда аргументы
          purrcorectl status
          purrcorectl purge
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }
}
