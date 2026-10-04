import Darwin
import Foundation
import IOKit
import IOKit.ps

public struct SSDSnapshot: Codable, Equatable, Sendable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64

    public init(totalBytes: UInt64, freeBytes: UInt64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    public var usedBytes: UInt64 {
        totalBytes >= freeBytes ? totalBytes - freeBytes : 0
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(usedBytes) / Double(totalBytes), 1)
    }
}

public struct BatterySnapshot: Codable, Equatable, Sendable {
    public let percent: Double
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let minutesRemaining: Int?

    public init(percent: Double, isCharging: Bool, isPluggedIn: Bool, minutesRemaining: Int?) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.minutesRemaining = minutesRemaining
    }
}

public enum StorageAndPowerSampler {
    public static func sampleSSD() -> SSDSnapshot? {
        var filesystem = statfs()
        guard statfs("/", &filesystem) == 0 else { return nil }

        return SSDSnapshot(
            totalBytes: UInt64(filesystem.f_blocks) * UInt64(filesystem.f_bsize),
            freeBytes: UInt64(filesystem.f_bavail) * UInt64(filesystem.f_bsize)
        )
    }

    public static func sampleBattery() -> BatterySnapshot? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source).takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType as String,
                let percent = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue
            else {
                continue
            }

            let isCharging = (description[kIOPSIsChargingKey as String] as? Bool) ?? false
            let isPluggedIn = description[kIOPSPowerSourceStateKey as String] as? String == kIOPSACPowerValue as String
            let minutesRemaining: Int?
            if isPluggedIn {
                minutesRemaining = nil
            } else {
                let seconds = IOPSGetTimeRemainingEstimate()
                minutesRemaining = seconds >= 0 ? Int(ceil(seconds / 60)) : nil
            }

            return BatterySnapshot(
                percent: min(max(percent, 0), 100),
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                minutesRemaining: minutesRemaining
            )
        }

        return nil
    }
}
