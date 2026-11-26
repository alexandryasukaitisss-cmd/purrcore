import Foundation

public enum CatSpeedPolicy {
    public static let idleRestThresholdPercent: Double = 3.0
    public static let idleWakeThresholdPercent: Double = 3.5
    public static let idleRestDelaySeconds: TimeInterval = 30.0
    public static let restingFrameIndex: Int = 2

    public static func frameInterval(cpuPercent: Double) -> TimeInterval {
        let normalizedLoad = min(max(cpuPercent, 0), 100) / 100
        return 0.20 - 0.12 * normalizedLoad
    }

    public static func evaluateRestState(
        cpuPercent: Double,
        idleSince: Date?,
        now: Date,
        currentlyResting: Bool,
        restWhenIdleEnabled: Bool
    ) -> (resting: Bool, updatedIdleSince: Date?) {
        guard restWhenIdleEnabled else {
            return (false, nil)
        }
        let clamped = min(max(cpuPercent, 0), 100)
        if currentlyResting {
            if clamped >= idleWakeThresholdPercent {
                return (false, nil)
            }
            return (true, idleSince ?? now)
        }
        if clamped < idleRestThresholdPercent {
            let start = idleSince ?? now
            if now.timeIntervalSince(start) >= idleRestDelaySeconds {
                return (true, start)
            }
            return (false, start)
        }
        return (false, nil)
    }
}
