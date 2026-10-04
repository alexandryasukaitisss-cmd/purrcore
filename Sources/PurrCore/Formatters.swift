import Foundation
import PurrCoreCore
import SwiftUI

enum MetricFormat {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func rate(_ value: Double) -> String {
        tr("%@/с", String(describing: bytes(UInt64(max(value, 0)))))
    }

    static func compactRate(_ value: Double) -> String {
        let safeValue = max(value, 0)
        let units: [(threshold: Double, divisor: Double, suffix: String)] = [
            (1_000_000_000, 1_000_000_000, tr("ГБ/с")),
            (1_000_000, 1_000_000, tr("МБ/с")),
            (1_000, 1_000, tr("КБ/с"))
        ]
        guard let unit = units.first(where: { safeValue >= $0.threshold }) else {
            return tr("%@ Б/с", String(describing: Int(safeValue.rounded())))
        }
        let amount = safeValue / unit.divisor
        let formatted = amount.formatted(.number.precision(.fractionLength(amount >= 10 ? 0 : 1)))
        return "\(formatted) \(unit.suffix)"
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value >= 10 ? 0 : 1))) + "%"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.down)), 0)
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return tr("%@ мин", String(describing: remainder)) }
        if remainder == 0 { return tr("%@ ч", String(describing: hours)) }
        return tr("%@ ч %@ мин", String(describing: hours), String(describing: remainder))
    }

    static func compactDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.down)), 0)
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return tr("%@м", String(describing: remainder)) }
        if remainder == 0 { return tr("%@ч", String(describing: hours)) }
        return tr("%@ч %@м", String(describing: hours), String(describing: remainder))
    }

    static func thermal(_ state: ThermalLevel) -> String {
        switch state {
        case .nominal: tr("норма")
        case .fair: tr("тепло")
        case .serious: tr("горячо")
        case .critical: tr("критично")
        case .unknown: tr("нет данных")
        }
    }

    static func pressure(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: tr("норма")
        case .warning: tr("повышено")
        case .critical: tr("критично")
        }
    }

    static func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

extension ProcessCategory {
    var color: Color {
        switch self {
        case .browser: .blue
        case .ai: .purple
        case .development: .orange
        case .communication: .cyan
        case .media: .pink
        case .system: .secondary
        case .other: .mint
        }
    }

    var symbol: String {
        switch self {
        case .browser: "globe"
        case .ai: "sparkles"
        case .development: "hammer"
        case .communication: "bubble.left.and.bubble.right"
        case .media: "play.rectangle"
        case .system: "gearshape.2"
        case .other: "app.dashed"
        }
    }
}
