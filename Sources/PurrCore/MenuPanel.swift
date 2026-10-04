import AppKit
import PurrCoreCore
import SwiftUI

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    let onOpenDashboard: () -> Void
    let onOpenSSDHealth: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

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
        .frame(width: 370)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            PetFrameImage(frame: model.catFrameIndex, animation: model.petAnimation)
                .frame(width: 62, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("PurrCore")
                    .font(.headline)
                Text(tr("питомец бежит в темпе нагрузки"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(MetricFormat.percent(model.snapshot.cpuPercent))
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
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

            MemoryBar(memory: model.snapshot.memory)

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
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(usageAccessibilityLabel(batterySession: batterySession))
        }
    }

    private func usageAccessibilityLabel(batterySession: BatterySessionRecord?) -> String {
        let today = MetricFormat.duration(model.usageReport.todayAwakeSeconds)
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
                    ProcessCompactRow(process: process)
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
    }
}
