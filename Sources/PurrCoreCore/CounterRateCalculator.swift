import Foundation

public struct CounterRateCalculator: Sendable {
    private var previousDownload: UInt64?
    private var previousUpload: UInt64?
    private var previousTimestamp: TimeInterval?

    public init() {}

    public mutating func update(
        downloadTotal: UInt64,
        uploadTotal: UInt64,
        timestamp: TimeInterval
    ) -> ThroughputSnapshot {
        defer {
            previousDownload = downloadTotal
            previousUpload = uploadTotal
            previousTimestamp = timestamp
        }

        guard
            let previousDownload,
            let previousUpload,
            let previousTimestamp,
            timestamp > previousTimestamp,
            downloadTotal >= previousDownload,
            uploadTotal >= previousUpload
        else {
            return .zero
        }

        let duration = timestamp - previousTimestamp
        return ThroughputSnapshot(
            downloadBytesPerSecond: Double(downloadTotal - previousDownload) / duration,
            uploadBytesPerSecond: Double(uploadTotal - previousUpload) / duration
        )
    }
}
