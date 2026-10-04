import Foundation

public struct UsageSegmentRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    public var endedAt: Date
    public var awakeSeconds: TimeInterval
    public var batteryAwakeSeconds: TimeInterval

    public init(
        id: String = UUID().uuidString,
        startedAt: Date,
        endedAt: Date,
        awakeSeconds: TimeInterval,
        batteryAwakeSeconds: TimeInterval
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.awakeSeconds = max(awakeSeconds, 0)
        self.batteryAwakeSeconds = min(max(batteryAwakeSeconds, 0), max(awakeSeconds, 0))
    }
}

public struct BatterySessionRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    public var endedAt: Date?
    public var lastObservedAt: Date
    public let startPercent: Double
    public var endPercent: Double
    public var awakeSeconds: TimeInterval
    public var startBoundaryKnown: Bool
    public var endBoundaryKnown: Bool

    public init(
        id: String = UUID().uuidString,
        startedAt: Date,
        endedAt: Date?,
        lastObservedAt: Date,
        startPercent: Double,
        endPercent: Double,
        awakeSeconds: TimeInterval,
        startBoundaryKnown: Bool,
        endBoundaryKnown: Bool
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastObservedAt = lastObservedAt
        self.startPercent = min(max(startPercent, 0), 100)
        self.endPercent = min(max(endPercent, 0), 100)
        self.awakeSeconds = max(awakeSeconds, 0)
        self.startBoundaryKnown = startBoundaryKnown
        self.endBoundaryKnown = endBoundaryKnown
    }

    public var consumedPercent: Double {
        max(startPercent - endPercent, 0)
    }

    public var hasKnownEstimateBoundary: Bool {
        startBoundaryKnown && (endedAt == nil || endBoundaryKnown)
    }

    public var isEstimateCandidate: Bool {
        hasKnownEstimateBoundary && consumedPercent >= 10 && awakeSeconds > 0
    }
}

public struct BatteryRuntimeEstimate: Codable, Equatable, Sendable {
    public let seconds: TimeInterval
    public let sessionCount: Int

    public init(seconds: TimeInterval, sessionCount: Int) {
        self.seconds = max(seconds, 0)
        self.sessionCount = max(sessionCount, 0)
    }
}

public enum UsageEstimator {
    public static func fullChargeEstimate(
        from sessions: [BatterySessionRecord],
        maximumSessions: Int = 3
    ) -> BatteryRuntimeEstimate? {
        let candidates = sessions
            .filter(\.isEstimateCandidate)
            .sorted { $0.lastObservedAt > $1.lastObservedAt }
            .prefix(max(maximumSessions, 1))

        guard candidates.count >= 2 else { return nil }
        let totalConsumed = candidates.reduce(0) { $0 + $1.consumedPercent }
        let totalAwake = candidates.reduce(0) { $0 + $1.awakeSeconds }
        guard totalConsumed > 0, totalAwake > 0 else { return nil }

        let seconds = totalAwake / totalConsumed * 100
        guard seconds.isFinite, seconds > 0 else { return nil }
        return BatteryRuntimeEstimate(seconds: seconds, sessionCount: candidates.count)
    }
}

public struct DailyUsagePoint: Identifiable, Codable, Equatable, Sendable {
    public var id: TimeInterval { day.timeIntervalSince1970 }

    public let day: Date
    public let awakeSeconds: TimeInterval
    public let batteryAwakeSeconds: TimeInterval

    public init(day: Date, awakeSeconds: TimeInterval, batteryAwakeSeconds: TimeInterval) {
        self.day = day
        self.awakeSeconds = max(awakeSeconds, 0)
        self.batteryAwakeSeconds = min(max(batteryAwakeSeconds, 0), max(awakeSeconds, 0))
    }
}

public struct UsageReport: Codable, Equatable, Sendable {
    public let daily: [DailyUsagePoint]
    public let todayAwakeSeconds: TimeInterval
    public let todayBatteryAwakeSeconds: TimeInterval
    public let currentBatterySession: BatterySessionRecord?
    public let latestBatterySession: BatterySessionRecord?
    public let fullChargeEstimate: BatteryRuntimeEstimate?

    public init(
        daily: [DailyUsagePoint],
        todayAwakeSeconds: TimeInterval,
        todayBatteryAwakeSeconds: TimeInterval,
        currentBatterySession: BatterySessionRecord?,
        latestBatterySession: BatterySessionRecord?,
        fullChargeEstimate: BatteryRuntimeEstimate?
    ) {
        self.daily = daily
        self.todayAwakeSeconds = max(todayAwakeSeconds, 0)
        self.todayBatteryAwakeSeconds = max(todayBatteryAwakeSeconds, 0)
        self.currentBatterySession = currentBatterySession
        self.latestBatterySession = latestBatterySession
        self.fullChargeEstimate = fullChargeEstimate
    }

    public static let empty = UsageReport(
        daily: [],
        todayAwakeSeconds: 0,
        todayBatteryAwakeSeconds: 0,
        currentBatterySession: nil,
        latestBatterySession: nil,
        fullChargeEstimate: nil
    )
}

public struct UsagePersistenceBatch: Equatable, Sendable {
    public let completedUsageSegments: [UsageSegmentRecord]
    public let currentUsageSegment: UsageSegmentRecord?
    public let completedBatterySessions: [BatterySessionRecord]
    public let activeBatterySession: BatterySessionRecord?

    public init(
        completedUsageSegments: [UsageSegmentRecord],
        currentUsageSegment: UsageSegmentRecord?,
        completedBatterySessions: [BatterySessionRecord],
        activeBatterySession: BatterySessionRecord?
    ) {
        self.completedUsageSegments = completedUsageSegments
        self.currentUsageSegment = currentUsageSegment
        self.completedBatterySessions = completedBatterySessions
        self.activeBatterySession = activeBatterySession
    }

    public var isEmpty: Bool {
        completedUsageSegments.isEmpty
            && currentUsageSegment == nil
            && completedBatterySessions.isEmpty
            && activeBatterySession == nil
    }
}

public struct UsageTracker: Sendable {
    private enum PowerSourceState {
        case battery
        case external
        case unavailable
    }

    private let maximumContinuousGap: TimeInterval
    private var isSuspended = true
    private var lastObservationAt: Date?
    private var lastBattery: BatterySnapshot?
    private var currentUsageSegmentState: UsageSegmentRecord?
    private var activeBatterySessionState: BatterySessionRecord?
    private var restoredActiveBatterySession = false
    private var completedUsageSegmentStates: [UsageSegmentRecord] = []
    private var completedBatterySessionStates: [BatterySessionRecord] = []

    public init(
        activeBatterySession: BatterySessionRecord? = nil,
        maximumContinuousGap: TimeInterval = 5
    ) {
        activeBatterySessionState = activeBatterySession
        restoredActiveBatterySession = activeBatterySession != nil
        self.maximumContinuousGap = max(maximumContinuousGap, 1)
    }

    public var currentBatterySession: BatterySessionRecord? {
        activeBatterySessionState
    }

    public mutating func resume(
        at timestamp: Date,
        battery: BatterySnapshot?,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        if !isSuspended, lastObservationAt != nil {
            observe(at: timestamp, battery: battery, calendar: calendar)
            return
        }

        isSuspended = false
        startUsageSegment(at: timestamp)
        if restoredActiveBatterySession,
           let active = activeBatterySessionState,
           timestamp.timeIntervalSince(active.lastObservedAt) > maximumContinuousGap
        {
            activeBatterySessionState?.startBoundaryKnown = false
        }
        restoredActiveBatterySession = false
        reconcileAfterUnobservedGap(at: timestamp, battery: battery)
        lastObservationAt = timestamp
        lastBattery = battery
    }

    public mutating func observe(
        at timestamp: Date,
        battery: BatterySnapshot?,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        guard !isSuspended, let previousTimestamp = lastObservationAt else {
            resume(at: timestamp, battery: battery, calendar: calendar)
            return
        }

        let interval = timestamp.timeIntervalSince(previousTimestamp)
        guard interval >= 0, interval <= maximumContinuousGap else {
            closeUsageSegment()
            startUsageSegment(at: timestamp)
            reconcileAfterUnobservedGap(at: timestamp, battery: battery)
            lastObservationAt = timestamp
            lastBattery = battery
            return
        }

        if interval > 0 {
            accrue(
                from: previousTimestamp,
                to: timestamp,
                onBattery: powerState(for: lastBattery) == .battery,
                calendar: calendar
            )
        }
        reconcileContiguousPowerTransition(from: lastBattery, to: battery, at: timestamp)
        lastObservationAt = timestamp
        lastBattery = battery
    }

    public mutating func suspend(
        at timestamp: Date,
        battery: BatterySnapshot?,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        guard !isSuspended else { return }
        observe(at: timestamp, battery: battery, calendar: calendar)
        closeUsageSegment()
        isSuspended = true
        lastObservationAt = timestamp
        lastBattery = battery
    }

    public func persistenceBatch() -> UsagePersistenceBatch {
        UsagePersistenceBatch(
            completedUsageSegments: completedUsageSegmentStates,
            currentUsageSegment: currentUsageSegmentState.flatMap { $0.awakeSeconds > 0 ? $0 : nil },
            completedBatterySessions: completedBatterySessionStates,
            activeBatterySession: activeBatterySessionState
        )
    }

    public mutating func acknowledgePersistence(of batch: UsagePersistenceBatch) {
        let usageIDs = Set(batch.completedUsageSegments.map(\.id))
        let batteryIDs = Set(batch.completedBatterySessions.map(\.id))
        completedUsageSegmentStates.removeAll { usageIDs.contains($0.id) }
        completedBatterySessionStates.removeAll { batteryIDs.contains($0.id) }
    }

    private mutating func accrue(
        from start: Date,
        to end: Date,
        onBattery: Bool,
        calendar: Calendar
    ) {
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let sliceEnd = min(end, nextDay)
            let seconds = max(sliceEnd.timeIntervalSince(cursor), 0)

            if currentUsageSegmentState == nil {
                startUsageSegment(at: cursor)
            }
            currentUsageSegmentState?.endedAt = sliceEnd
            currentUsageSegmentState?.awakeSeconds += seconds
            if onBattery {
                currentUsageSegmentState?.batteryAwakeSeconds += seconds
                activeBatterySessionState?.awakeSeconds += seconds
            }

            cursor = sliceEnd
            if cursor < end || calendar.startOfDay(for: cursor) != dayStart {
                closeUsageSegment()
                if cursor < end {
                    startUsageSegment(at: cursor)
                }
            }
        }
    }

    private mutating func startUsageSegment(at timestamp: Date) {
        currentUsageSegmentState = UsageSegmentRecord(
            startedAt: timestamp,
            endedAt: timestamp,
            awakeSeconds: 0,
            batteryAwakeSeconds: 0
        )
    }

    private mutating func closeUsageSegment() {
        guard let segment = currentUsageSegmentState else { return }
        if segment.awakeSeconds > 0 {
            completedUsageSegmentStates.append(segment)
        }
        currentUsageSegmentState = nil
    }

    private func powerState(for battery: BatterySnapshot?) -> PowerSourceState {
        guard let battery else { return .unavailable }
        return battery.isPluggedIn ? .external : .battery
    }

    private mutating func reconcileContiguousPowerTransition(
        from previous: BatterySnapshot?,
        to current: BatterySnapshot?,
        at timestamp: Date
    ) {
        switch (powerState(for: previous), powerState(for: current)) {
        case (.external, .battery):
            if activeBatterySessionState != nil {
                finalizeActiveBatterySession(at: timestamp, percent: current?.percent, boundaryKnown: false)
            }
            startBatterySession(at: timestamp, percent: current?.percent ?? 0, boundaryKnown: true)
        case (.battery, .external):
            finalizeActiveBatterySession(at: timestamp, percent: current?.percent, boundaryKnown: true)
        case (.battery, .battery):
            if activeBatterySessionState == nil {
                startBatterySession(at: timestamp, percent: current?.percent ?? 0, boundaryKnown: false)
            }
            updateActiveBatterySession(at: timestamp, percent: current?.percent)
        case (.unavailable, .battery):
            if activeBatterySessionState == nil {
                startBatterySession(at: timestamp, percent: current?.percent ?? 0, boundaryKnown: false)
            }
            updateActiveBatterySession(at: timestamp, percent: current?.percent)
        case (.unavailable, .external):
            finalizeActiveBatterySession(at: timestamp, percent: current?.percent, boundaryKnown: false)
        case (.external, .external):
            if activeBatterySessionState != nil {
                finalizeActiveBatterySession(at: timestamp, percent: current?.percent, boundaryKnown: false)
            }
        case (_, .unavailable):
            break
        }
    }

    private mutating func reconcileAfterUnobservedGap(at timestamp: Date, battery: BatterySnapshot?) {
        switch powerState(for: battery) {
        case .external:
            finalizeActiveBatterySession(at: timestamp, percent: battery?.percent, boundaryKnown: false)
        case .battery:
            if let active = activeBatterySessionState, let percent = battery?.percent,
               percent > active.endPercent + 2
            {
                finalizeActiveBatterySession(
                    at: timestamp,
                    percent: active.endPercent,
                    boundaryKnown: false
                )
                startBatterySession(at: timestamp, percent: percent, boundaryKnown: false)
            } else if activeBatterySessionState == nil {
                startBatterySession(at: timestamp, percent: battery?.percent ?? 0, boundaryKnown: false)
            }
            updateActiveBatterySession(at: timestamp, percent: battery?.percent)
        case .unavailable:
            break
        }
    }

    private mutating func startBatterySession(at timestamp: Date, percent: Double, boundaryKnown: Bool) {
        activeBatterySessionState = BatterySessionRecord(
            startedAt: timestamp,
            endedAt: nil,
            lastObservedAt: timestamp,
            startPercent: percent,
            endPercent: percent,
            awakeSeconds: 0,
            startBoundaryKnown: boundaryKnown,
            endBoundaryKnown: false
        )
    }

    private mutating func updateActiveBatterySession(at timestamp: Date, percent: Double?) {
        guard var session = activeBatterySessionState else { return }
        session.lastObservedAt = timestamp
        if let percent {
            session.endPercent = min(max(percent, 0), 100)
        }
        activeBatterySessionState = session
    }

    private mutating func finalizeActiveBatterySession(
        at timestamp: Date,
        percent: Double?,
        boundaryKnown: Bool
    ) {
        guard var session = activeBatterySessionState else { return }
        session.endedAt = timestamp
        session.lastObservedAt = timestamp
        if let percent {
            session.endPercent = min(max(percent, 0), 100)
        }
        session.endBoundaryKnown = boundaryKnown
        completedBatterySessionStates.append(session)
        activeBatterySessionState = nil
    }
}
