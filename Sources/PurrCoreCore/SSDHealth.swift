import CoreFoundation
import Foundation
import IOKit

public enum SSDHealthStatus: String, Codable, CaseIterable, Sendable {
    case healthy
    case warning
    case critical
    case unavailable
}

public struct SSDHealthSnapshot: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let status: SSDHealthStatus
    public let model: String?
    public let mediaType: String?
    public let protocolName: String?
    public let capacityBytes: UInt64?
    public let smartStatus: Bool?
    public let criticalWarning: UInt8?
    public let temperatureC: Double?
    public let availableSparePercent: Double?
    public let spareThresholdPercent: Double?
    public let percentageUsed: Double?
    public let dataUnitsReadTB: Double?
    public let dataUnitsWrittenTB: Double?
    public let powerCycles: UInt64?
    public let powerOnHours: UInt64?
    public let unsafeShutdowns: UInt64?
    public let mediaErrors: UInt64?
    public let errorLogEntries: UInt64?

    public init(
        timestamp: Date = .now,
        model: String? = nil,
        mediaType: String? = nil,
        protocolName: String? = nil,
        capacityBytes: UInt64? = nil,
        smartStatus: Bool? = nil,
        criticalWarning: UInt8? = nil,
        temperatureC: Double? = nil,
        availableSparePercent: Double? = nil,
        spareThresholdPercent: Double? = nil,
        percentageUsed: Double? = nil,
        dataUnitsReadTB: Double? = nil,
        dataUnitsWrittenTB: Double? = nil,
        powerCycles: UInt64? = nil,
        powerOnHours: UInt64? = nil,
        unsafeShutdowns: UInt64? = nil,
        mediaErrors: UInt64? = nil,
        errorLogEntries: UInt64? = nil
    ) {
        self.timestamp = timestamp
        self.model = model
        self.mediaType = mediaType
        self.protocolName = protocolName
        self.capacityBytes = capacityBytes
        self.smartStatus = smartStatus
        self.criticalWarning = criticalWarning
        self.temperatureC = temperatureC
        self.availableSparePercent = availableSparePercent
        self.spareThresholdPercent = spareThresholdPercent
        self.percentageUsed = percentageUsed
        self.dataUnitsReadTB = dataUnitsReadTB
        self.dataUnitsWrittenTB = dataUnitsWrittenTB
        self.powerCycles = powerCycles
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaErrors = mediaErrors
        self.errorLogEntries = errorLogEntries
        self.status = SSDHealthScoring.status(
            smartStatus: smartStatus,
            criticalWarning: criticalWarning,
            temperatureC: temperatureC,
            availableSparePercent: availableSparePercent,
            spareThresholdPercent: spareThresholdPercent,
            percentageUsed: percentageUsed,
            dataUnitsReadTB: dataUnitsReadTB,
            dataUnitsWrittenTB: dataUnitsWrittenTB,
            powerCycles: powerCycles,
            powerOnHours: powerOnHours,
            unsafeShutdowns: unsafeShutdowns,
            mediaErrors: mediaErrors,
            errorLogEntries: errorLogEntries
        )
    }
}

public enum SSDHealthScoring {
    public static func status(
        smartStatus: Bool?,
        criticalWarning: UInt8?,
        temperatureC: Double?,
        availableSparePercent: Double?,
        spareThresholdPercent: Double?,
        percentageUsed: Double?,
        dataUnitsReadTB: Double?,
        dataUnitsWrittenTB: Double?,
        powerCycles: UInt64?,
        powerOnHours: UInt64?,
        unsafeShutdowns: UInt64?,
        mediaErrors: UInt64?,
        errorLogEntries: UInt64?
    ) -> SSDHealthStatus {
        let hasMetrics = [
            criticalWarning != nil,
            temperatureC != nil,
            availableSparePercent != nil,
            spareThresholdPercent != nil,
            percentageUsed != nil,
            dataUnitsReadTB != nil,
            dataUnitsWrittenTB != nil,
            powerCycles != nil,
            powerOnHours != nil,
            unsafeShutdowns != nil,
            mediaErrors != nil,
            errorLogEntries != nil
        ].contains(true)

        guard smartStatus != nil || hasMetrics else { return .unavailable }
        if smartStatus == false || criticalWarning.map({ $0 != 0 }) == true || mediaErrors.map({ $0 > 0 }) == true {
            return .critical
        }
        if temperatureC.map({ $0 >= 70 }) == true
            || percentageUsed.map({ $0 >= 80 }) == true
            || (availableSparePercent != nil && spareThresholdPercent != nil
                && availableSparePercent! <= spareThresholdPercent!)
        {
            return .warning
        }
        return .healthy
    }
}

public struct SSDHealthDiskInfo: Equatable, Sendable {
    public let model: String?
    public let mediaType: String?
    public let protocolName: String?
    public let capacityBytes: UInt64?
    public let smartStatus: Bool?

    public init(
        model: String? = nil,
        mediaType: String? = nil,
        protocolName: String? = nil,
        capacityBytes: UInt64? = nil,
        smartStatus: Bool? = nil
    ) {
        self.model = model
        self.mediaType = mediaType
        self.protocolName = protocolName
        self.capacityBytes = capacityBytes
        self.smartStatus = smartStatus
    }
}

public enum SSDHealthFallbackParser {
    public static func parse(_ output: String) -> SSDHealthDiskInfo {
        let smartValue = value(for: ["SMART Status"], in: output)?.lowercased()
        let smartStatus: Bool?
        if let smartValue {
            if smartValue.contains("fail") || smartValue.contains("error") {
                smartStatus = false
            } else if smartValue.contains("verified") || smartValue.contains("pass") || smartValue == "ok" {
                smartStatus = true
            } else {
                smartStatus = nil
            }
        } else {
            smartStatus = nil
        }

        let mediaType: String?
        if value(for: ["Solid State"], in: output)?.lowercased() == "yes" {
            mediaType = "SSD"
        } else if let media = value(for: ["Media Type"], in: output) {
            mediaType = media
        } else {
            mediaType = nil
        }

        return SSDHealthDiskInfo(
            model: value(for: ["Device / Media Name", "Device Model"], in: output),
            mediaType: mediaType,
            protocolName: value(for: ["Protocol"], in: output),
            capacityBytes: parseCapacityBytes(value(for: ["Disk Size"], in: output)),
            smartStatus: smartStatus
        )
    }

    public static func physicalDiskIdentifier(from output: String) -> String? {
        let raw = (value(for: ["APFS Physical Store"], in: output) ?? value(for: ["Device Identifier"], in: output))?
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init)
            .map { $0.hasPrefix("/dev/") ? String($0.dropFirst(5)) : $0 }
        guard let raw, raw.hasPrefix("disk") else { return nil }

        let suffix = raw.dropFirst(4)
        let components = suffix.split(separator: "s", maxSplits: 1).map(String.init)
        let diskNumber = components.first ?? ""
        guard !diskNumber.isEmpty, diskNumber.allSatisfy(\.isNumber) else { return nil }
        if components.count == 2 {
            guard !components[1].isEmpty, components[1].allSatisfy(\.isNumber) else { return nil }
        }
        return "disk\(diskNumber)"
    }

    private static func value(for labels: [String], in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2 else { continue }
            if labels.contains(where: { $0.caseInsensitiveCompare(parts[0]) == .orderedSame }) {
                return parts[1].isEmpty ? nil : parts[1]
            }
        }
        return nil
    }

    private static func parseCapacityBytes(_ value: String?) -> UInt64? {
        guard let value else { return nil }
        for part in value.split(whereSeparator: { $0 == "(" || $0 == ")" }) {
            guard part.localizedCaseInsensitiveContains("bytes") else { continue }
            let digits = part.unicodeScalars.filter { (48...57).contains($0.value) }
            if let result = UInt64(String(String.UnicodeScalarView(digits))) {
                return result
            }
        }
        return nil
    }
}

public struct SSDHealthNVMeMetrics: Equatable, Sendable {
    public let criticalWarning: UInt8?
    public let temperatureC: Double?
    public let availableSparePercent: Double?
    public let spareThresholdPercent: Double?
    public let percentageUsed: Double?
    public let dataUnitsReadTB: Double?
    public let dataUnitsWrittenTB: Double?
    public let powerCycles: UInt64?
    public let powerOnHours: UInt64?
    public let unsafeShutdowns: UInt64?
    public let mediaErrors: UInt64?
    public let errorLogEntries: UInt64?

    fileprivate init(
        criticalWarning: UInt8?,
        temperatureC: Double?,
        availableSparePercent: Double?,
        spareThresholdPercent: Double?,
        percentageUsed: Double?,
        dataUnitsReadTB: Double?,
        dataUnitsWrittenTB: Double?,
        powerCycles: UInt64?,
        powerOnHours: UInt64?,
        unsafeShutdowns: UInt64?,
        mediaErrors: UInt64?,
        errorLogEntries: UInt64?
    ) {
        self.criticalWarning = criticalWarning
        self.temperatureC = temperatureC
        self.availableSparePercent = availableSparePercent
        self.spareThresholdPercent = spareThresholdPercent
        self.percentageUsed = percentageUsed
        self.dataUnitsReadTB = dataUnitsReadTB
        self.dataUnitsWrittenTB = dataUnitsWrittenTB
        self.powerCycles = powerCycles
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaErrors = mediaErrors
        self.errorLogEntries = errorLogEntries
    }
}

public enum SSDHealthNVMeDecoder {
    public static func decode(data: [UInt8]) -> SSDHealthNVMeMetrics? {
        guard data.count >= 192 else { return nil }
        return SSDHealthNVMeMetrics(
            criticalWarning: data[0],
            temperatureC: temperatureC(from: readUInt16(data, offset: 1)),
            availableSparePercent: Double(data[3]),
            spareThresholdPercent: Double(data[4]),
            percentageUsed: Double(data[5]),
            dataUnitsReadTB: decodeDataUnitsTB(low: readUInt64(data, offset: 32), high: readUInt64(data, offset: 40)),
            dataUnitsWrittenTB: decodeDataUnitsTB(low: readUInt64(data, offset: 48), high: readUInt64(data, offset: 56)),
            powerCycles: decodeUInt64Counter(data, offset: 112),
            powerOnHours: decodeUInt64Counter(data, offset: 128),
            unsafeShutdowns: decodeUInt64Counter(data, offset: 144),
            mediaErrors: decodeUInt64Counter(data, offset: 160),
            errorLogEntries: decodeUInt64Counter(data, offset: 176)
        )
    }

    public static func decodeDataUnitsTB(low: UInt64, high: UInt64) -> Double {
        let units = Double(high) * 18_446_744_073_709_551_616 + Double(low)
        return units * 512_000 / 1_000_000_000_000
    }

    private static func temperatureC(from raw: UInt16) -> Double? {
        guard raw != 0, raw != .max else { return nil }
        return Double(raw) - 273.15
    }

    private static func decodeUInt64Counter(_ data: [UInt8], offset: Int) -> UInt64? {
        let low = readUInt64(data, offset: offset)
        let high = readUInt64(data, offset: offset + 8)
        return high == 0 ? low : nil
    }

    private static func readUInt16(_ data: [UInt8], offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt64(_ data: [UInt8], offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].enumerated().reduce(UInt64(0)) { result, item in
            result | UInt64(item.element) << UInt64(item.offset * 8)
        }
    }
}

public enum SSDHealthReaderError: LocalizedError, Sendable {
    case commandFailed(String)
    case physicalSystemDiskNotFound

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .physicalSystemDiskNotFound: "Не удалось определить физический системный диск."
        }
    }
}

public struct SSDHealthReader: Sendable {
    public init() {}

    public func read() throws -> SSDHealthSnapshot {
        let runner = DiskutilRunner()
        let rootInfo = try runner.info(for: "/")
        guard let diskIdentifier = SSDHealthFallbackParser.physicalDiskIdentifier(from: rootInfo) else {
            throw SSDHealthReaderError.physicalSystemDiskNotFound
        }
        let diskInfoOutput = try runner.info(for: "/dev/\(diskIdentifier)")
        let diskInfo = SSDHealthFallbackParser.parse(diskInfoOutput)

        return snapshot(deviceIdentifier: diskIdentifier, diskInfo: diskInfo)
    }

    func snapshot(deviceIdentifier: String, diskInfo: SSDHealthDiskInfo) -> SSDHealthSnapshot {
        if let native = NativeNVMeReader.read(deviceIdentifier: deviceIdentifier) {
            return snapshot(diskInfo: diskInfo, nativeModel: native.model, nativeSmartStatus: native.smartStatus, metrics: native.metrics)
        }

        return SSDHealthSnapshot(
            model: diskInfo.model,
            mediaType: diskInfo.mediaType,
            protocolName: diskInfo.protocolName,
            capacityBytes: diskInfo.capacityBytes,
            smartStatus: diskInfo.smartStatus
        )
    }

    func snapshot(diskInfo: SSDHealthDiskInfo, nativeModel: String?, nativeSmartStatus: Bool, metrics: SSDHealthNVMeMetrics) -> SSDHealthSnapshot {
        return SSDHealthSnapshot(
            model: nativeModel ?? diskInfo.model,
            mediaType: diskInfo.mediaType,
            protocolName: diskInfo.protocolName,
            capacityBytes: diskInfo.capacityBytes,
            smartStatus: diskInfo.smartStatus == false ? false : nativeSmartStatus,
            criticalWarning: metrics.criticalWarning,
            temperatureC: metrics.temperatureC,
            availableSparePercent: metrics.availableSparePercent,
            spareThresholdPercent: metrics.spareThresholdPercent,
            percentageUsed: metrics.percentageUsed,
            dataUnitsReadTB: metrics.dataUnitsReadTB,
            dataUnitsWrittenTB: metrics.dataUnitsWrittenTB,
            powerCycles: metrics.powerCycles,
            powerOnHours: metrics.powerOnHours,
            unsafeShutdowns: metrics.unsafeShutdowns,
            mediaErrors: metrics.mediaErrors,
            errorLogEntries: metrics.errorLogEntries
        )
    }

}

private struct DiskutilRunner: Sendable {
    func info(for path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", path]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            throw SSDHealthReaderError.commandFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "diskutil завершился с ошибкой"
            throw SSDHealthReaderError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private enum NativeNVMeReader {
    private typealias QueryInterfaceFunction = @convention(c) (UnsafeMutableRawPointer?, CFUUIDBytes, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    private typealias ReleaseFunction = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    private typealias ReadDataFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias IdentifyDataFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> Int32

    private struct COMInterfacePrefix {
        let reserved: UnsafeMutableRawPointer?
        let queryInterface: QueryInterfaceFunction?
        let addRef: UnsafeMutableRawPointer?
        let release: ReleaseFunction?
    }

    private struct InterfacePrefix {
        let reserved: UnsafeMutableRawPointer?
        let queryInterface: QueryInterfaceFunction?
        let addRef: UnsafeMutableRawPointer?
        let release: ReleaseFunction?
        let version: UInt16
        let revision: UInt16
        let readData: ReadDataFunction?
        let identifyData: IdentifyDataFunction?
    }

    fileprivate struct Reading {
        let metrics: SSDHealthNVMeMetrics
        let model: String?
        let smartStatus: Bool
    }

    fileprivate static func read(deviceIdentifier: String) -> Reading? {
        let matching = IOBSDNameMatching(kIOMainPortDefault, 0, deviceIdentifier)
        var service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }

        while service != 0 && !isSMARTCapable(service) {
            var parent: io_registry_entry_t = 0
            let child = service
            guard IORegistryEntryGetParentEntry(child, kIOServicePlane, &parent) == KERN_SUCCESS else {
                IOObjectRelease(child)
                return nil
            }
            IOObjectRelease(child)
            service = parent
        }
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let userClientUUID = CFUUIDCreateFromString(nil, "AA0FA6F9-C2D6-457F-B10B-59A13253292F" as CFString)
        let interfaceUUID = CFUUIDCreateFromString(nil, "CCD1DB19-FD9A-4DAF-BF95-12454B230AB6" as CFString)
        let pluginInterfaceUUID = CFUUIDCreateFromString(nil, "C244E858-109C-11D4-91D4-0050E4C6426F" as CFString)
        guard let userClientUUID, let interfaceUUID, let pluginInterfaceUUID else { return nil }

        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(
            service,
            userClientUUID,
            pluginInterfaceUUID,
            &plugin,
            &score
        ) == KERN_SUCCESS, let plugin else { return nil }
        defer { IODestroyPlugInInterface(plugin) }
        guard let pluginTable = plugin.pointee else { return nil }

        let pluginPrefix = UnsafeMutableRawPointer(pluginTable).assumingMemoryBound(to: COMInterfacePrefix.self).pointee
        guard let queryInterface = pluginPrefix.queryInterface else { return nil }
        var smartInterface: UnsafeMutableRawPointer?
        guard queryInterface(
            UnsafeMutableRawPointer(plugin),
            CFUUIDGetUUIDBytes(interfaceUUID),
            &smartInterface
        ) == 0, let smartInterfaceValue = smartInterface else { return nil }

        let interfaceTablePointer = smartInterfaceValue.assumingMemoryBound(
            to: UnsafeMutablePointer<InterfacePrefix>.self
        ).pointee
        defer { _ = interfaceTablePointer.pointee.release?(smartInterfaceValue) }
        guard let readData = interfaceTablePointer.pointee.readData else { return nil }

        var smartBytes = [UInt8](repeating: 0, count: 512)
        let readStatus = smartBytes.withUnsafeMutableBytes { buffer in
            readData(smartInterfaceValue, buffer.baseAddress)
        }
        guard readStatus == 0, let metrics = SSDHealthNVMeDecoder.decode(data: smartBytes) else { return nil }

        var model: String?
        if let identifyData = interfaceTablePointer.pointee.identifyData {
            var identifyBytes = [UInt8](repeating: 0, count: 4_096)
            let identifyStatus = identifyBytes.withUnsafeMutableBytes { buffer in
                identifyData(smartInterfaceValue, buffer.baseAddress, 0)
            }
            if identifyStatus == 0 {
                model = decodeText(identifyBytes, offset: 24, length: 40)
            }
        }
        return Reading(metrics: metrics, model: model, smartStatus: true)
    }

    private static func isSMARTCapable(_ service: io_registry_entry_t) -> Bool {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "NVMe SMART Capable" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func decodeText(_ data: [UInt8], offset: Int, length: Int) -> String? {
        guard data.count >= offset + length else { return nil }
        let bytes = data[offset..<(offset + length)]
        let value = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
