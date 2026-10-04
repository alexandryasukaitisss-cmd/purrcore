import Foundation

public enum CatSpeedPolicy {
    public static func frameInterval(cpuPercent: Double) -> TimeInterval {
        let normalizedLoad = min(max(cpuPercent, 0), 100) / 100
        return 0.20 - 0.12 * normalizedLoad
    }
}
