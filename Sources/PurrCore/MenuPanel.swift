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
        .frame(width: 404)
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
                    .font(.system(size: 13))
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
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.09))
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
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.07))
            Divider()
        default:
            EmptyView()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            AnimatedPetView(
                cpuPercent: model.snapshot.cpuPercent,
                animationEnabled: animationEnabled,
                isResting: model.isPetResting,
                reduceMotion: reduceMotion,
                customFrames: model.petAnimation
            )
            .frame(width: 52, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("PurrCore")
                    .font(.system(size: 14, weight: .semibold))
                Text(model.isPetResting
                    ? tr("питомец дремлет · нагрузка низкая")
                    : tr("питомец бежит в темпе нагрузки"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 4) {
                Text(MetricFormat.percent(model.snapshot.cpuPercent))
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                CoreLoadStrip(
                    perCoreCPU: model.snapshot.perCoreCPU,
                    coreClusters: model.snapshot.coreClusters,
                    coreCount: model.snapshot.coreCount,
                    compact: true
                )
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var summary: some View {
        VStack(spacing: 11) {
            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tr("Память"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(MetricFormat.bytes(model.snapshot.memory.usedBytes)) / \(MetricFormat.bytes(model.snapshot.memory.totalBytes))")
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle()
                            .fill(MetricFormat.pressureColor(model.snapshot.memory.pressure))
                            .frame(width: 6, height: 6)
                        Text(MetricFormat.pressure(model.snapshot.memory.pressure))
                            .font(.caption)
                            .foregroundStyle(
                                model.snapshot.memory.pressure == .normal
                                    ? Color.secondary
                                    : MetricFormat.pressureColor(model.snapshot.memory.pressure)
                            )
                    }
                }

                MemoryBar(memory: model.snapshot.memory)

                if model.snapshot.memory.swapUsedBytes > 0 {
                    let swapElevated = model.snapshot.memory.pressure != .normal && model.snapshot.memory.swapUsedBytes >= 1_073_741_824
                    HStack {
                        Text("Swap")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(MetricFormat.bytes(model.snapshot.memory.swapUsedBytes))
                            .foregroundStyle(swapElevated ? Color.orange : Color.secondary)
                    }
                    .font(.caption2)
                    .monospacedDigit()
                }
            }

            if let ssd = model.ssd {
                let lowDisk = ssd.totalBytes > 0 && ssd.freeBytes < SmartAlertTracker.lowDiskThresholdBytes
                VStack(spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("SSD")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(MetricFormat.bytes(ssd.usedBytes)) / \(MetricFormat.bytes(ssd.totalBytes))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(lowDisk ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }
                    CapacityBar(fraction: ssd.usedFraction, color: lowDisk ? .orange : .blue.opacity(0.82))
                }
            }

            if let battery = model.battery {
                HStack(spacing: 5) {
                    Image(systemName: batterySymbol(for: battery))
                        .font(.system(size: 11))
                    Text(batteryText(for: battery))
                    Spacer()
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel(batteryText(for: battery))
            }

            usageSummary

            telemetryLedgerStrip

            liveWarningBanner
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private var telemetryLedgerStrip: some View {
        var cells: [(label: String, value: String, color: Color)] = []
        if let gpu = model.snapshot.gpuPercent {
            cells.append(("GPU", MetricFormat.percent(gpu), .primary))
        }
        cells.append((tr("Сеть ↓"), MetricFormat.compactRate(model.snapshot.network.downloadBytesPerSecond), .primary))
        cells.append((tr("Диск"), MetricFormat.compactRate(model.snapshot.disk.downloadBytesPerSecond + model.snapshot.disk.uploadBytesPerSecond), .primary))
        cells.append((tr("Тепло"), MetricFormat.thermal(model.snapshot.thermalState), MetricFormat.thermalColor(model.snapshot.thermalState)))

        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(cell.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(cell.value)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(cell.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var liveWarningBanner: some View {
        if model.snapshot.memory.pressure == .critical {
            let leader = model.snapshot.processes.max(by: { $0.residentBytes < $1.residentBytes })
            warningStrip(
                symbol: "exclamationmark.triangle.fill",
                text: leader.map { tr("Память критична · лидер: %@ (%@)", tr($0.displayName), MetricFormat.shortBytes($0.residentBytes)) }
                    ?? tr("Критическое давление памяти macOS"),
                color: .red
            )
        } else if model.snapshot.thermalState == .serious || model.snapshot.thermalState == .critical {
            warningStrip(
                symbol: "flame.fill",
                text: tr("Mac ограничивает частоты из-за нагрева"),
                color: .orange
            )
        } else if let ssd = model.ssd, ssd.totalBytes > 0, ssd.freeBytes < SmartAlertTracker.lowDiskThresholdBytes {
            warningStrip(
                symbol: "internaldrive.trianglebadge.exclamationmark",
                text: tr("Свободно на SSD всего %@", MetricFormat.shortBytes(ssd.freeBytes)),
                color: .orange
            )
        }
    }

    private func warningStrip(symbol: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: 6,
                bottomLeadingRadius: 6,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(color)
            .frame(width: 2.5)
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

            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text(tr("Сегодня без сна"))
                    Spacer()
                    Text(MetricFormat.compactDuration(model.usageReport.todayAwakeSeconds))
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }

                if model.hasInternalBattery {
                    HStack(spacing: 8) {
                        Text(dischargeLabel)
                        Text(batterySession.map { MetricFormat.compactDuration($0.awakeSeconds) } ?? "—")
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("0–100%")
                        Text(model.usageReport.fullChargeEstimate.map { "≈ " + MetricFormat.compactDuration($0.seconds) } ?? "—")
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(tr("КТО СЕЙЧАС ЕСТ РЕСУРСЫ"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 2) {
                    sortChip(title: "CPU", mode: .cpu)
                    sortChip(title: tr("Память"), mode: .memory)
                }
                .padding(2)
                .background(Color.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
            }

            if topProcesses.isEmpty {
                Text(tr("Собираю первый подробный срез…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 2) {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func sortChip(title: String, mode: ProcessHistorySort) -> some View {
        let selected = activeProcessSort == mode
        return Button {
            manualSortOverride = mode
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            PopoverFooterButton(title: tr("История"), symbol: "chart.xyaxis.line") {
                NSApp.activate(ignoringOtherApps: true)
                onOpenDashboard()
            }
            .keyboardShortcut("h")

            PopoverFooterButton(title: "SSD", symbol: "internaldrive") {
                NSApp.activate(ignoringOtherApps: true)
                onOpenSSDHealth()
            }

            PopoverFooterButton(title: tr("Настройки"), symbol: "gearshape") {
                NSApp.activate(ignoringOtherApps: true)
                onOpenSettings()
            }
            .keyboardShortcut(",")

            Spacer(minLength: 6)

            PopoverFooterButton(title: tr("Выйти"), symbol: nil, action: onQuit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct PopoverFooterButton: View {
    let title: String
    let symbol: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
            }
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
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
        let pillWidth: CGFloat = compact ? (count > 14 ? 3 : 3.5) : (count > 16 ? 6 : 8)
        let pillHeight: CGFloat = compact ? 9 : 18
        let spacing: CGFloat = compact ? 1.5 : 3

        HStack(spacing: compact ? 4 : 8) {
            if hasClusters {
                HStack(spacing: compact ? 3.5 : 7) {
                    clusterGroup(label: "P", loads: performanceLoads, pillWidth: pillWidth, pillHeight: pillHeight, spacing: spacing)
                    Circle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 2, height: 2)
                    clusterGroup(label: "E", loads: efficiencyLoads, pillWidth: pillWidth, pillHeight: pillHeight, spacing: spacing)
                }
            } else {
                barsRow(loads: sortedLoads, pillWidth: pillWidth, pillHeight: pillHeight, spacing: spacing)
            }
            Text("(\(busyCores)/\(totalCores))")
                .font(compact ? .caption2 : .caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Загружено %@ из %@ ядер", String(describing: busyCores), String(describing: totalCores)))
        .help(helpDescription)
    }

    private func clusterGroup(label: String, loads: [Double], pillWidth: CGFloat, pillHeight: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: compact ? 2 : 4) {
            Text(label)
                .font(.system(size: compact ? 8.5 : 10, weight: .semibold))
                .foregroundStyle(.secondary)
            barsRow(loads: loads, pillWidth: pillWidth, pillHeight: pillHeight, spacing: spacing)
        }
    }

    private func barsRow(loads: [Double], pillWidth: CGFloat, pillHeight: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                if compact {
                    RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                        .fill(MetricFormat.coreLoadColor(load).opacity(load >= 35 ? 0.95 : 0.68))
                        .frame(width: pillWidth, height: pillHeight)
                } else {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
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

struct MemoryBar: View {
    let memory: MemorySnapshot

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(memory.totalBytes), 1)
            HStack(spacing: 1) {
                segment(width: geometry.size.width * Double(memory.appBytes) / total, color: .blue.opacity(0.85))
                segment(width: geometry.size.width * Double(memory.wiredBytes) / total, color: .orange.opacity(0.85))
                segment(width: geometry.size.width * Double(memory.compressedBytes) / total, color: .teal.opacity(0.85))
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .frame(height: 6)
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
                .background(Color.primary.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .frame(height: 6)
    }
}

struct ProcessActionMenuItems: View {
    let process: ProcessGroupSample
    var onCompleted: (() -> Void)? = nil

    var body: some View {
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
                onCompleted?()
            }
            Button(tr("Принудительно завершить…"), role: .destructive) {
                ProcessActions.confirmAndForceQuit(process)
                onCompleted?()
            }
        }
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
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(process.category.color.opacity(0.85))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(tr(process.displayName))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(tr(process.explanation))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Menu {
                ProcessActionMenuItems(process: process, onCompleted: onProcessActionCompleted)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20, height: 20)
            .opacity(isHovered ? 0.95 : 0.24)
            .help(tr("Действия с процессом"))

            Text(MetricFormat.percent(process.cpuPercent))
                .font(.system(size: 12, weight: sortMode == .cpu ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(sortMode == .cpu ? .primary : .secondary)
                .frame(width: 46, alignment: .trailing)

            Text(MetricFormat.bytes(process.residentBytes))
                .font(.system(size: 12, weight: sortMode == .memory ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(sortMode == .memory ? .primary : .secondary)
                .frame(width: 68, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            ProcessActionMenuItems(process: process, onCompleted: onProcessActionCompleted)
        }
        .help(MetricFormat.processCPU(process, totalCores: totalCores))
    }
}
