import Darwin
import Foundation
import IOKit

public struct ExternalSSDVolume: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let mountPoint: String?
    public let isWritable: Bool?
}

public struct ExternalSSDIOStatistics: Codable, Equatable, Sendable {
    public let readErrors: UInt64?
    public let writeErrors: UInt64?
    public let readRetries: UInt64?
    public let writeRetries: UInt64?
    public let bytesRead: UInt64?
    public let bytesWritten: UInt64?

    public var hasCompleteErrorCounters: Bool {
        [readErrors, writeErrors, readRetries, writeRetries].allSatisfy { $0 != nil }
    }

    public var hasIssues: Bool {
        [readErrors, writeErrors, readRetries, writeRetries].contains { ($0 ?? 0) > 0 }
    }
}

public struct ExternalSSDHealthReport: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let deviceIdentifier: String
    public let displayName: String
    public let health: SSDHealthSnapshot
    public let volumes: [ExternalSSDVolume]
    public let usbLinkMbps: Double?
    public let isWritable: Bool?
    public let storage: SSDSnapshot?
    public var ioStatistics: ExternalSSDIOStatistics? = nil
}

enum ExternalSSDParsing {
    static func ioStatistics(_ value: Any?) -> ExternalSSDIOStatistics? {
        guard let values = value as? [String: Any] else { return nil }
        func counter(_ key: String) -> UInt64? {
            guard let number = values[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = UInt64(number.stringValue) else { return nil }
            return value
        }
        let statistics = ExternalSSDIOStatistics(
            readErrors: counter("Errors (Read)"), writeErrors: counter("Errors (Write)"),
            readRetries: counter("Retries (Read)"), writeRetries: counter("Retries (Write)"),
            bytesRead: counter("Bytes (Read)"), bytesWritten: counter("Bytes (Write)"))
        return [statistics.readErrors, statistics.writeErrors, statistics.readRetries,
                statistics.writeRetries, statistics.bytesRead, statistics.bytesWritten]
            .contains(where: { $0 != nil }) ? statistics : nil
    }

    static func eligible(_ info: [String: Any]) -> Bool {
        (info["Internal"] as? Bool) == false && (info["SolidState"] as? Bool) != false
    }

    static func disks(_ list: [String: Any]) -> [String] {
        (list["WholeDisks"] as? [String] ?? []).filter { $0.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil }
    }

    static func mount(_ value: Any?) -> String? {
        guard let path = value as? String else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func candidates(_ list: [String: Any], disk: String) -> [[String: Any]] {
        guard let whole = (list["AllDisksAndPartitions"] as? [[String: Any]])?.first(where: { ($0["DeviceIdentifier"] as? String) == disk }) else { return [] }
        let partitions = whole["Partitions"] as? [[String: Any]] ?? []
        return partitions.isEmpty ? [whole] : partitions
    }

    static func isAPFS(_ value: [String: Any]) -> Bool {
        ["Content", "PartitionType", "FilesystemType"].contains {
            (value[$0] as? String)?.localizedCaseInsensitiveContains("APFS") == true
        }
    }

    static func isUserFilesystem(_ detail: [String: Any]) -> Bool {
        guard let filesystem = detail["FilesystemType"] as? String, !filesystem.isEmpty else { return false }
        return !["APFS", "EFI"].contains { filesystem.localizedCaseInsensitiveContains($0) }
            && !["EFI", "Apple_APFS"].contains { marker in
                (detail["Content"] as? String)?.localizedCaseInsensitiveContains(marker) == true
            }
    }

    static func summarize(
        pools: [[String: Any]],
        candidates: [[String: Any]],
        details: [String: [String: Any]],
        filesystemStorage: [String: SSDSnapshot],
        apfsAvailable: Bool
    ) -> (volumes: [ExternalSSDVolume], storage: SSDSnapshot?) {
        var volumes: [ExternalSSDVolume] = []
        var seen = Set<String>()
        var total: UInt64 = 0
        var free: UInt64 = 0
        var complete = true
        var counted = false
        for pool in pools {
            if let size = poolStorage(pool) {
                let (newTotal, totalOverflow) = total.addingReportingOverflow(size.totalBytes)
                let (newFree, freeOverflow) = free.addingReportingOverflow(size.freeBytes)
                if totalOverflow || freeOverflow { complete = false }
                else { total = newTotal; free = newFree; counted = true }
            } else { complete = false }
            for volume in pool["Volumes"] as? [[String: Any]] ?? [] {
                guard let id = volume["DeviceIdentifier"] as? String, seen.insert(id).inserted else { continue }
                let detail = details[id]
                volumes.append(ExternalSSDVolume(id: id,
                    name: (detail?["VolumeName"] as? String) ?? (volume["Name"] as? String) ?? id,
                    mountPoint: mount(detail?["MountPoint"]), isWritable: detail?["Writable"] as? Bool))
            }
        }
        for candidate in candidates {
            guard let id = candidate["DeviceIdentifier"] as? String else { continue }
            if isAPFS(candidate) { if !apfsAvailable || pools.isEmpty { complete = false }; continue }
            guard let detail = details[id] else { complete = false; continue }
            if isAPFS(detail) { if !apfsAvailable || pools.isEmpty { complete = false }; continue }
            guard isUserFilesystem(detail), seen.insert(id).inserted else { continue }
            let path = mount(detail["MountPoint"])
            volumes.append(ExternalSSDVolume(id: id,
                name: (detail["VolumeName"] as? String) ?? (candidate["VolumeName"] as? String) ?? id,
                mountPoint: path, isWritable: detail["Writable"] as? Bool))
            guard path != nil, let size = filesystemStorage[id] else { complete = false; continue }
            let (newTotal, totalOverflow) = total.addingReportingOverflow(size.totalBytes)
            let (newFree, freeOverflow) = free.addingReportingOverflow(size.freeBytes)
            if totalOverflow || freeOverflow { complete = false }
            else { total = newTotal; free = newFree; counted = true }
        }
        return (volumes, complete && counted ? SSDSnapshot(totalBytes: total, freeBytes: free) : nil)
    }

    static func smart(_ value: Any?) -> Bool? {
        guard let text = value as? String else { return nil }
        let lower = text.lowercased()
        if lower.contains("fail") || lower.contains("error") { return false }
        if lower.contains("verified") || lower.contains("pass") { return true }
        return nil
    }

    static func speed(_ value: Any?) -> Double? {
        guard let code = (value as? NSNumber)?.intValue else { return nil }
        return [0: 1.5, 1: 12, 2: 480, 3: 5000, 4: 10000, 5: 20000][code]
    }

    static func pools(_ apfs: [String: Any]) -> [[String: Any]] {
        apfs["Containers"] as? [[String: Any]] ?? []
    }

    static func storeIDs(_ pool: [String: Any]) -> [String] {
        (pool["PhysicalStores"] as? [[String: Any]] ?? []).compactMap { $0["DeviceIdentifier"] as? String }
    }

    static func poolStorage(_ pool: [String: Any]) -> SSDSnapshot? {
        guard storeIDs(pool).count == 1,
              let total = (pool["CapacityCeiling"] as? NSNumber)?.uint64Value,
              let free = (pool["CapacityFree"] as? NSNumber)?.uint64Value,
              free <= total else { return nil }
        return SSDSnapshot(totalBytes: total, freeBytes: free)
    }
}

private enum ExternalDiskutil {
    static func plist(_ arguments: [String]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { throw SSDHealthReaderError.commandFailed(error.localizedDescription) }
        // Drain before waiting: diskutil's APFS plist can exceed a pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SSDHealthReaderError.commandFailed(String(data: data, encoding: .utf8) ?? "diskutil failed")
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SSDHealthReaderError.commandFailed("Invalid diskutil plist")
        }
        return plist
    }
}

private struct ExternalRegistry {
    let id: UInt64
    let vendor: String?
    let product: String?
    let speed: Double?
    let ioStatistics: ExternalSSDIOStatistics?

    static func read(_ disk: String) -> ExternalRegistry? {
        var service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, disk))
        guard service != 0 else { return nil }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else {
            IOObjectRelease(service)
            return nil
        }
        var vendor: String?
        var product: String?
        var speed: Double?
        var ioStatistics: ExternalSSDIOStatistics?
        while service != 0 {
            if ioStatistics == nil, IOObjectConformsTo(service, "IOBlockStorageDriver") != 0 {
                let values = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                ioStatistics = ExternalSSDParsing.ioStatistics(values)
            }
            if IOObjectConformsTo(service, "IOUSBHostDevice") != 0 {
                vendor = IORegistryEntryCreateCFProperty(service, "USB Vendor Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                product = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                let code = IORegistryEntryCreateCFProperty(service, "Device Speed" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                speed = ExternalSSDParsing.speed(code)
                break
            }
            var parent: io_registry_entry_t = 0
            let child = service
            guard IORegistryEntryGetParentEntry(child, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(child)
            service = parent
        }
        IOObjectRelease(service)
        return ExternalRegistry(id: registryID, vendor: vendor, product: product, speed: speed, ioStatistics: ioStatistics)
    }
}

extension SSDHealthReader {
    public func readExternalDisks() throws -> [ExternalSSDHealthReport] {
        let listing = try ExternalDiskutil.plist(["list", "-plist", "external", "physical"])
        let apfs = try? ExternalDiskutil.plist(["apfs", "list", "-plist"])
        return ExternalSSDParsing.disks(listing).compactMap { disk in
            guard let before = ExternalRegistry.read(disk),
                  let info = try? ExternalDiskutil.plist(["info", "-plist", disk]),
                  ExternalSSDParsing.eligible(info) else { return nil }
            let pools = (apfs.map(ExternalSSDParsing.pools) ?? []).filter { pool in
                ExternalSSDParsing.storeIDs(pool).contains { $0 == disk || $0.hasPrefix(disk + "s") }
            }
            let candidates = ExternalSSDParsing.candidates(listing, disk: disk)
            let apfsVolumes = pools.flatMap { $0["Volumes"] as? [[String: Any]] ?? [] }
            let identifiers = Set((candidates + apfsVolumes).compactMap { $0["DeviceIdentifier"] as? String })
            var details: [String: [String: Any]] = [:]
            var filesystemStorage: [String: SSDSnapshot] = [:]
            for identifier in identifiers {
                guard let detail = try? ExternalDiskutil.plist(["info", "-plist", identifier]) else { continue }
                details[identifier] = detail
                guard let mount = ExternalSSDParsing.mount(detail["MountPoint"]),
                      ExternalSSDParsing.isUserFilesystem(detail) else { continue }
                var fs = statfs()
                if statfs(mount, &fs) == 0 {
                    filesystemStorage[identifier] = SSDSnapshot(
                        totalBytes: UInt64(fs.f_blocks) * UInt64(fs.f_bsize),
                        freeBytes: UInt64(fs.f_bavail) * UInt64(fs.f_bsize))
                }
            }
            let summary = ExternalSSDParsing.summarize(pools: pools, candidates: candidates,
                details: details, filesystemStorage: filesystemStorage, apfsAvailable: apfs != nil)
            let model = info["MediaName"] as? String ?? info["DeviceName"] as? String
            let diskInfo = SSDHealthDiskInfo(model: model, mediaType: info["SolidState"] as? Bool == true ? "SSD" : nil, protocolName: info["BusProtocol"] as? String, capacityBytes: (info["TotalSize"] as? NSNumber)?.uint64Value, smartStatus: ExternalSSDParsing.smart(info["SMARTStatus"]))
            let name = [before.vendor, before.product].compactMap { $0 }.joined(separator: " ")
            let health = snapshot(deviceIdentifier: disk, diskInfo: diskInfo)
            guard ExternalRegistry.read(disk)?.id == before.id else { return nil }
            return ExternalSSDHealthReport(id: "\(before.id):\(disk)", deviceIdentifier: disk, displayName: name.isEmpty ? (model ?? disk) : name, health: health, volumes: summary.volumes, usbLinkMbps: before.speed, isWritable: info["Writable"] as? Bool, storage: summary.storage, ioStatistics: before.ioStatistics)
        }
    }
}
