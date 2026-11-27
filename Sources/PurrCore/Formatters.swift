import Foundation
import PurrCoreCore
import SwiftUI

enum MetricFormat {
    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: value))
    }

    static func shortBytes(_ value: UInt64) -> String {
        let doubleValue = Double(value)
        let gigabyte = 1_073_741_824.0
        let megabyte = 1_048_576.0
        let kilobyte = 1_024.0
        if doubleValue >= gigabyte {
            let amount = doubleValue / gigabyte
            let formatted = amount.formatted(.number.precision(.fractionLength(amount >= 10 ? 0 : 1)))
            return tr("%@ ГБ", formatted)
        }
        if doubleValue >= megabyte {
            let amount = doubleValue / megabyte
            let formatted = amount.formatted(.number.precision(.fractionLength(0)))
            return tr("%@ МБ", formatted)
        }
        if doubleValue >= kilobyte {
            let amount = doubleValue / kilobyte
            let formatted = amount.formatted(.number.precision(.fractionLength(0)))
            return tr("%@ КБ", formatted)
        }
        return tr("%@ Б", String(describing: value))
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

    static func axisPercent(_ value: Double) -> String {
        "\(Int(max(value, 0).rounded()))%"
    }

    static func processCPU(_ sample: ProcessGroupSample, totalCores: Int) -> String {
        let base = percent(sample.cpuPercent)
        let cores = sample.equivalentCores(totalCores: totalCores)
        guard cores >= 0.1 else { return base }
        let formattedCores = cores.formatted(.number.precision(.fractionLength(cores >= 10 ? 0 : 1)))
        return tr("%@ (%@ яд.)", base, formattedCores)
    }

    static func coreLoadColor(_ percent: Double) -> Color {
        if percent >= 70 { return .red }
        if percent >= 35 { return .orange }
        return .green
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

    static func thermalColor(_ state: ThermalLevel) -> Color {
        switch state {
        case .nominal: .primary
        case .fair: .orange
        case .serious: .orange
        case .critical: .red
        case .unknown: .secondary
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
        case .ai: .indigo
        case .development: .orange
        case .communication: .teal
        case .media: .pink
        case .system: .secondary
        case .other: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .browser: "globe"
        case .ai: "terminal"
        case .development: "hammer"
        case .communication: "bubble.left.and.bubble.right"
        case .media: "play.rectangle"
        case .system: "gearshape.2"
        case .other: "app"
        }
    }
}
