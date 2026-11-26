import AppKit
import PurrCoreCore
import SwiftUI

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    let onOpenDashboard: () -> Void
    let onOpenSSDHealth: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @AppStorage(AppDefaults.animationEnabled) private var animationEnabled = true
    @AppStorage(AppDefaults.statusMetric) private var statusMetric = StatusMetric.cpu.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var manualSortOverride: ProcessHistorySort?

    private var activeProcessSort: ProcessHistorySort {
        if let manualSortOverride {
            return manualSortOverride
        }
        return statusMetric == StatusMetric.memory.rawValue ? .memory : .cpu
    }

    private var topProcesses: [ProcessGroupSample] {
        let sorted = model.snapshot.processes.sorted { lhs, rhs in
            switch activeProcessSort {
            case .memory:
                if lhs.residentBytes != rhs.residentBytes {
                    return lhs.residentBytes > rhs.residentBytes
                }
                return lhs.cpuPercent > rhs.cpuPercent
            case .cpu:
                if lhs.cpuPercent != rhs.cpuPercent {
                    return lhs.cpuPercent > rhs.cpuPercent
                }
                return lhs.residentBytes > rhs.residentBytes
            }
        }
        return Array(sorted.prefix(5))
    }

    var body: some View {
        VStack(spacing: 0) {
            updateBanner
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
        .onChange(of: statusMetric) { _, _ in
            manualSortOverride = nil
        }
    }

    @ViewBuilder
    private var updateBanner: some View {
        switch updater.state {
        case .available(let candidate):
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("Доступно обновление (%@)", candidate.shortSHA))
                        .font(.caption.weight(.semibold))
                    if !candidate.commitTitle.isEmpty {
                        Text(candidate.commitTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Button(tr("Обновить сейчас")) {
                    updater.installAvailableUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.blue.opacity(0.10))
            .help(candidate.commitTitle)
            Divider()
        case .installing(let progressText):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.blue.opacity(0.08))
            Divider()
        default:
            EmptyView()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AnimatedPetView(
                cpuPercent: model.snapshot.cpuPercent,
                animationEnabled: animationEnabled,
                isResting: model.isPetResting,
                reduceMotion: reduceMotion,
                customFrames: model.petAnimation
            )
            .frame(width: 76, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("PurrCore")
                    .font(.headline)
                Text(model.isPetResting
                    ? tr("питомец дремлет · нагрузка низкая")
                    : tr("питомец бежит в темпе нагрузки"))
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
                    coreClusters: model.snapshot.coreClusters,
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
                MetricSummary(
                    label: tr("Память"),
                    value: "\(MetricFormat.bytes(model.snapshot.memory.usedBytes)) / \(MetricFormat.bytes(model.snapshot.memory.totalBytes))",
                    color: .purple
                )
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

            HStack(spacing: model.snapshot.gpuPercent != nil ? 12 : 18) {
                if let gpu = model.snapshot.gpuPercent {
                    MetricSummary(label: "GPU", value: MetricFormat.percent(gpu), color: .indigo)
                }
                MetricSummary(label: tr("Сеть ↓"), value: MetricFormat.rate(model.snapshot.network.downloadBytesPerSecond), color: .green)
                MetricSummary(label: tr("Диск"), value: MetricFormat.rate(model.snapshot.disk.downloadBytesPerSecond + model.snapshot.disk.uploadBytesPerSecond), color: .orange)
                MetricSummary(label: tr("Тепло"), value: MetricFormat.thermal(model.snapshot.thermalState), color: .secondary)
            }

            liveWarningBanner
        }
        .padding(16)
    }

    @ViewBuilder
    private var liveWarningBanner: some View {
        if model.snapshot.memory.pressure == .critical {
            let leader = model.snapshot.processes.max(by: { $0.residentBytes < $1.residentBytes })
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(leader.map { tr("Память критична · лидер: %@ (%@)", tr($0.displayName), MetricFormat.shortBytes($0.residentBytes)) }
                    ?? tr("Критическое давление памяти macOS"))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.red)
        } else if model.snapshot.thermalState == .serious || model.snapshot.thermalState == .critical {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                Text(tr("Mac ограничивает частоты из-за нагрева"))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.orange)
        } else if let ssd = model.ssd, ssd.totalBytes > 0, ssd.freeBytes < SmartAlertTracker.lowDiskThresholdBytes {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                Text(tr("Свободно на SSD всего %@", MetricFormat.shortBytes(ssd.freeBytes)))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.orange)
        }
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
            HStack(spacing: 8) {
                Text(tr("КТО СЕЙЧАС ЕСТ РЕСУРСЫ"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 2) {
                    sortChip(title: "CPU", mode: .cpu)
                    sortChip(title: tr("Память"), mode: .memory)
                }
                .padding(2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if topProcesses.isEmpty {
                Text(tr("Собираю первый подробный срез…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(topProcesses) { process in
                    ProcessCompactRow(
                        process: process,
                        totalCores: model.snapshot.coreCount,
                        sortMode: activeProcessSort,
                        onProcessActionCompleted: {
                            model.requestImmediateProcessRefresh()
                        }
                    )
                }
            }
        }
        .padding(16)
    }

    private func sortChip(title: String, mode: ProcessHistorySort) -> some View {
        let selected = activeProcessSort == mode
        return Button {
            manualSortOverride = mode
        } label: {
            Text(title)
                .font(.caption2.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                )
        }
        .buttonStyle(.plain)
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
    var coreClusters: [CoreClusterKind] = []
    let coreCount: Int
    var compact: Bool = true

    private var hasClusters: Bool {
        coreClusters.count == perCoreCPU.count
            && coreClusters.contains(.efficiency)
            && coreClusters.contains(.performance)
    }

    private var performanceLoads: [Double] {
        guard hasClusters else { return [] }
        return zip(coreClusters, perCoreCPU).compactMap { $0 == .performance ? $1 : nil }.sorted(by: >)
    }

    private var efficiencyLoads: [Double] {
        guard hasClusters else { return [] }
        return zip(coreClusters, perCoreCPU).compactMap { $0 == .efficiency ? $1 : nil }.sorted(by: >)
    }

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

    private var helpDescription: String {
        if hasClusters {
            let pBusy = performanceLoads.filter { $0 >= 35 }.count
            let eBusy = efficiencyLoads.filter { $0 >= 35 }.count
            return tr(
                "Производительных (P): %@/%@ · Энергоэффективных (E): %@/%@",
                String(describing: pBusy),
                String(describing: performanceLoads.count),
                String(describing: eBusy),
                String(describing: efficiencyLoads.count)
            )
        }
        return tr("Активных ядер: %@ из %@ (красные ≥70%, оранжевые 35–69%, зелёные <35%)", String(describing: busyCores), String(describing: totalCores))
    }

    var body: some View {
        let count = totalCores
        let pillWidth: CGFloat = compact ? (count > 14 ? 3 : 4) : (count > 16 ? 6 : 8)
        let pillHeight: CGFloat = compact ? 9 : 18
        let spacing: CGFloat = compact ? (count > 14 ? 1.5 : 2) : 3

        HStack(spacing: compact ? 5 : 8) {
            if hasClusters {
                HStack(spacing: compact ? 4 : 7) {
                    clusterGroup(label: "P", loads: performanceLoads, pillWidth: pillWidth, pillHeight: pillHeight, spacing: spacing)
                    Circle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 2.5, height: 2.5)
                    clusterGroup(label: "E", loads: efficiencyLoads, pillWidth: pillWidth, pillHeight: pillHeight, spacing: spacing)
                }
            } else {
                barsRow(loads: sortedLoads, pillWidth: pillWidth, pillHeight: pillHeight, spacing: spacing)
            }
            Text("(\(busyCores)/\(totalCores))")
                .font(compact ? .caption2 : .caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Загружено %@ из %@ ядер", String(describing: busyCores), String(describing: totalCores)))
        .help(helpDescription)
    }

    private func clusterGroup(label: String, loads: [Double], pillWidth: CGFloat, pillHeight: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: compact ? 2 : 4) {
            Text(label)
                .font(.system(size: compact ? 8.5 : 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            barsRow(loads: loads, pillWidth: pillWidth, pillHeight: pillHeight, spacing: spacing)
        }
    }

    private func barsRow(loads: [Double], pillWidth: CGFloat, pillHeight: CGFloat, spacing: CGFloat) -> some View {
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
    var sortMode: ProcessHistorySort = .cpu
    var onProcessActionCompleted: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
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
            Spacer(minLength: 4)
            if isHovered {
                Menu {
                    actionMenuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("Действия с процессом"))
            }
            Text(MetricFormat.percent(process.cpuPercent))
                .monospacedDigit()
                .fontWeight(sortMode == .cpu ? .medium : .regular)
                .foregroundStyle(sortMode == .cpu ? .primary : .secondary)
            Text(MetricFormat.bytes(process.residentBytes))
                .monospacedDigit()
                .fontWeight(sortMode == .memory ? .medium : .regular)
                .foregroundStyle(sortMode == .memory ? .primary : .secondary)
                .frame(width: 68, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            actionMenuItems
        }
        .help(MetricFormat.processCPU(process, totalCores: totalCores))
    }

    @ViewBuilder
    private var actionMenuItems: some View {
        if process.bundlePath != nil {
            Button(tr("Показать в Finder")) {
                ProcessActions.revealInFinder(process)
            }
        }
        Button(tr("Открыть Мониторинг системы")) {
            ProcessActions.openActivityMonitor()
        }
        if process.canTerminate {
            Divider()
            Button(tr("Завершить")) {
                ProcessActions.quit(process)
                onProcessActionCompleted?()
            }
            Button(tr("Принудительно завершить…"), role: .destructive) {
                ProcessActions.confirmAndForceQuit(process)
                onProcessActionCompleted?()
            }
        }
    }
}
