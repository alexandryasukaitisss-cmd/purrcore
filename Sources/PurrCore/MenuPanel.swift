import AppKit
import PurrCoreCore
import SwiftUI

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    let onOpenDashboard: () -> Void
    let onOpenSSDHealth: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @AppStorage(AppDefaults.animationEnabled) private var animationEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var topProcesses: [ProcessGroupSample] {
        Array(model.snapshot.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summary
            Divider()
            topConsumers
            Divider()
            footer
        }
        .frame(width: 376)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AnimatedPetView(
                cpuPercent: model.snapshot.cpuPercent,
                animationEnabled: animationEnabled,
                reduceMotion: reduceMotion,
                customFrames: model.petAnimation
            )
            .frame(width: 76, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("PurrCore")
                    .font(.headline)
                Text(tr("питомец бежит в темпе нагрузки"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(MetricFormat.percent(model.snapshot.cpuPercent))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                CoreLoadStrip(
                    perCoreCPU: model.snapshot.perCoreCPU,
                    coreCount: model.snapshot.coreCount,
                    compact: true
                )
            }
        }
        .padding(16)
    }

    private var summary: some View {
        VStack(spacing: 12) {
            HStack {
                MetricSummary(label: tr("Память"), value: "\(MetricFormat.bytes(model.snapshot.memory.usedBytes)) / \(MetricFormat.bytes(model.snapshot.memory.totalBytes))", color: .purple)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(MetricFormat.pressureColor(model.snapshot.memory.pressure))
                        .frame(width: 7, height: 7)
                    Text(MetricFormat.pressure(model.snapshot.memory.pressure))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 5) {
                MemoryBar(memory: model.snapshot.memory)
                if model.snapshot.memory.swapUsedBytes > 0 {
                    HStack {
                        Text("Swap")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(MetricFormat.bytes(model.snapshot.memory.swapUsedBytes))
                            .foregroundStyle(.pink)
                    }
                    .font(.caption2)
                    .monospacedDigit()
                }
            }

            if let ssd = model.ssd {
                VStack(spacing: 6) {
                    HStack {
                        Text("SSD")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(MetricFormat.bytes(ssd.usedBytes)) / \(MetricFormat.bytes(ssd.totalBytes))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    CapacityBar(fraction: ssd.usedFraction, color: .blue)
                }
            }

            if let battery = model.battery {
                HStack(spacing: 5) {
                    Image(systemName: batterySymbol(for: battery))
                    Text(batteryText(for: battery))
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(batteryText(for: battery))
            }

            usageSummary

            HStack(spacing: 18) {
                MetricSummary(label: tr("Сеть ↓"), value: MetricFormat.rate(model.snapshot.network.downloadBytesPerSecond), color: .green)
                MetricSummary(label: tr("Диск"), value: MetricFormat.rate(model.snapshot.disk.downloadBytesPerSecond + model.snapshot.disk.uploadBytesPerSecond), color: .orange)
                MetricSummary(label: tr("Тепло"), value: MetricFormat.thermal(model.snapshot.thermalState), color: .secondary)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var usageSummary: some View {
        if model.historyError != nil {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(tr("Учёт времени недоступен"))
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
            let batterySession = model.usageReport.currentBatterySession ?? model.usageReport.latestBatterySession
            let dischargeLabel = model.usageReport.currentBatterySession == nil ? tr("Последний разряд") : tr("Этот разряд")

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text(tr("Сегодня без сна"))
                    Spacer()
                    Text(MetricFormat.compactDuration(model.usageReport.todayAwakeSeconds))
                        .foregroundStyle(.primary)
                }

                if model.hasInternalBattery {
                    HStack(spacing: 8) {
                        Text(dischargeLabel)
                        Text(batterySession.map { MetricFormat.compactDuration($0.awakeSeconds) } ?? "—")
                            .foregroundStyle(.green)
                        Spacer()
                        Text("0–100")
                        Text(model.usageReport.fullChargeEstimate.map { "≈ " + MetricFormat.compactDuration($0.seconds) } ?? "—")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(usageAccessibilityLabel(batterySession: batterySession))
        }
    }

    private func usageAccessibilityLabel(batterySession: BatterySessionRecord?) -> String {
        let today = MetricFormat.duration(model.usageReport.todayAwakeSeconds)
        guard model.hasInternalBattery else {
            return tr("Сегодня без сна %@.", String(describing: today))
        }
        let discharge = batterySession.map { MetricFormat.duration($0.awakeSeconds) } ?? tr("нет данных")
        let estimate = model.usageReport.fullChargeEstimate.map { MetricFormat.duration($0.seconds) } ?? tr("нет оценки")
        return tr("Сегодня без сна %@. Работа от батареи %@. Оценка от нуля до ста процентов %@.", String(describing: today), String(describing: discharge), String(describing: estimate))
    }

    private func batterySymbol(for battery: BatterySnapshot) -> String {
        if battery.isCharging { return "battery.100.bolt" }
        if battery.percent >= 80 { return "battery.100" }
        if battery.percent >= 40 { return "battery.50" }
        return "battery.25"
    }

    private func batteryText(for battery: BatterySnapshot) -> String {
        let percent = Int(battery.percent.rounded())
        if battery.isCharging { return tr("%@% · Заряжается", String(describing: percent)) }
        if battery.isPluggedIn { return tr("%@% · От сети", String(describing: percent)) }
        guard let minutes = battery.minutesRemaining else { return tr("%@% · На батарее", String(describing: percent)) }
        return tr("%@% · Осталось %@ ч %@ мин", String(describing: percent), String(describing: minutes / 60), String(describing: String(format: "%02d", minutes % 60)))
    }

    private var topConsumers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("КТО СЕЙЧАС ЕСТ РЕСУРСЫ"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if topProcesses.isEmpty {
                Text(tr("Собираю первый подробный срез…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(topProcesses) { process in
                    ProcessCompactRow(process: process, totalCores: model.snapshot.coreCount)
                }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button(tr("История")) {
                NSApp.activate(ignoringOtherApps: true)
                onOpenDashboard()
            }
            .keyboardShortcut("h")

            Button("SSD") {
                NSApp.activate(ignoringOtherApps: true)
                onOpenSSDHealth()
            }

            Button(tr("Настройки")) {
                NSApp.activate(ignoringOtherApps: true)
                onOpenSettings()
            }
            Spacer()
            Button(tr("Выйти"), action: onQuit)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(14)
    }
}

struct CoreLoadStrip: View {
    let perCoreCPU: [Double]
    let coreCount: Int
    var compact: Bool = true

    private var sortedLoads: [Double] {
        if perCoreCPU.isEmpty {
            return Array(repeating: 0, count: max(coreCount, 1))
        }
        return perCoreCPU.sorted(by: >)
    }

    private var totalCores: Int {
        max(perCoreCPU.count, max(coreCount, 1))
    }

    private var busyCores: Int {
        sortedLoads.filter { $0 >= 35 }.count
    }

    var body: some View {
        let loads = sortedLoads
        let pillWidth: CGFloat = compact ? (loads.count > 14 ? 3 : 4) : (loads.count > 16 ? 6 : 8)
        let pillHeight: CGFloat = compact ? 9 : 18
        let spacing: CGFloat = compact ? (loads.count > 14 ? 1.5 : 2) : 3

        HStack(spacing: compact ? 5 : 8) {
            HStack(spacing: spacing) {
                ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                    if compact {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(MetricFormat.coreLoadColor(load).opacity(load >= 35 ? 0.95 : 0.72))
                            .frame(width: pillWidth, height: pillHeight)
                    } else {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(Color.secondary.opacity(0.16))
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(MetricFormat.coreLoadColor(load))
                                .frame(height: max(3, pillHeight * min(max(load / 100, 0), 1)))
                        }
                        .frame(width: pillWidth, height: pillHeight)
                        .help(MetricFormat.percent(load))
                    }
                }
            }
            Text("(\(busyCores)/\(totalCores))")
                .font(compact ? .caption2 : .caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Загружено %@ из %@ ядер", String(describing: busyCores), String(describing: totalCores)))
        .help(tr("Активных ядер: %@ из %@ (красные ≥70%, оранжевые 35–69%, зелёные <35%)", String(describing: busyCores), String(describing: totalCores)))
    }
}

private struct MetricSummary: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

struct MemoryBar: View {
    let memory: MemorySnapshot

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(memory.totalBytes), 1)
            HStack(spacing: 1) {
                segment(width: geometry.size.width * Double(memory.appBytes) / total, color: .purple)
                segment(width: geometry.size.width * Double(memory.wiredBytes) / total, color: .orange)
                segment(width: geometry.size.width * Double(memory.compressedBytes) / total, color: .cyan)
                Spacer(minLength: 0)
            }
            .background(Color.secondary.opacity(0.16))
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityLabel(tr("Использовано памяти %@", String(describing: MetricFormat.percent(memory.usedFraction * 100))))
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        color.frame(width: max(width, 0))
    }
}

struct CapacityBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            color
                .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.16))
                .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

struct ProcessCompactRow: View {
    let process: ProcessGroupSample
    let totalCores: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: process.category.symbol)
                .foregroundStyle(process.category.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(process.displayName))
                    .lineLimit(1)
                Text(tr(process.explanation))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(MetricFormat.percent(process.cpuPercent))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(MetricFormat.bytes(process.residentBytes))
                .monospacedDigit()
                .frame(width: 68, alignment: .trailing)
        }
        .font(.callout)
        .help(MetricFormat.processCPU(process, totalCores: totalCores))
    }
}
