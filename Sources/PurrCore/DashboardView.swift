import Charts
import PurrCoreCore
import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case cpu
    case memory
    case network
    case disk
    case usage
    case tasks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: tr("Обзор")
        case .cpu: tr("Процессор")
        case .memory: tr("Память")
        case .network: tr("Сеть")
        case .disk: tr("Диск")
        case .usage: tr("Время")
        case .tasks: tr("Задачи")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "chart.xyaxis.line"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        case .usage: "clock.arrow.circlepath"
        case .tasks: "flag.checkered"
        }
    }
}

private enum ProcessScope: String, CaseIterable, Identifiable {
    case live
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: tr("Сейчас")
        case .history: tr("За период")
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var selection: DashboardSection?

    init(model: AppModel, initialSection: DashboardSection = .overview) {
        self.model = model
        _selection = State(initialValue: initialSection)
    }

    private var activeSection: DashboardSection {
        selection ?? .overview
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(DashboardSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .navigationTitle("PurrCore")
            .navigationSplitViewColumnWidth(min: 175, ideal: 200, max: 225)
        } detail: {
            VStack(spacing: 0) {
                dashboardToolbar
                Divider()
                detail(for: activeSection)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 880, minHeight: 600)
    }

    private var dashboardToolbar: some View {
        HStack(spacing: 10) {
            Text(activeSection.title)
                .font(.system(size: 15.5, weight: .semibold))
                .fixedSize()

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 14)

            Text(activeSection == .usage
                ? tr("Фактическое время работы без сна и выключений")
                : tr("История хранится локально 7 дней"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 12)

            if activeSection != .usage {
                Picker(tr("Период"), selection: $model.selectedRange) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(tr(range.title)).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 186)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }

    @ViewBuilder
    private func detail(for section: DashboardSection) -> some View {
        switch section {
        case .overview:
            OverviewDashboard(model: model)
        case .cpu:
            ProcessorDashboard(model: model)
        case .memory:
            MemoryDashboard(model: model)
        case .network:
            ThroughputDashboard(model: model, kind: .network)
        case .disk:
            ThroughputDashboard(model: model, kind: .disk)
        case .usage:
            UsageDashboard(model: model)
        case .tasks:
            TaskDashboard(model: model)
        }
    }
}

private struct LedgerItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    var subtitle: String? = nil
    var accentColor: Color? = nil
}

private struct LedgerStripCard: View {
    let items: [LedgerItem]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(item.value)
                        .font(.system(size: 21, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    if let accent = item.accentColor {
                        Rectangle()
                            .fill(accent)
                            .frame(height: 2)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct OverviewDashboard: View {
    @ObservedObject var model: AppModel

    private var memoryDetail: String {
        let base = tr(
            "из %@ · давление %@",
            String(describing: MetricFormat.bytes(model.snapshot.memory.totalBytes)),
            String(describing: MetricFormat.pressure(model.snapshot.memory.pressure))
        )
        guard model.snapshot.memory.swapUsedBytes > 0 else { return base }
        return "\(base) · Swap \(MetricFormat.shortBytes(model.snapshot.memory.swapUsedBytes))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let error = model.historyError {
                    UsageUnavailableCard(message: error)
                } else {
                    UsageOverviewCard(report: model.usageReport, showBattery: model.hasInternalBattery)
                }

                MetricHistoryCard(
                    title: tr("Процессор"),
                    value: MetricFormat.percent(model.snapshot.cpuPercent),
                    detail: tr("доля от всего Mac"),
                    color: .blue,
                    points: model.displayedHistory,
                    yValue: { $0.cpuPercent },
                    extraHeader: {
                        CoreLoadStrip(
                            perCoreCPU: model.snapshot.perCoreCPU,
                            coreClusters: model.snapshot.coreClusters,
                            coreCount: model.snapshot.coreCount,
                            compact: true
                        )
                    }
                )

                if let gpu = model.snapshot.gpuPercent {
                    MetricHistoryCard(
                        title: tr("Графика (GPU)"),
                        value: MetricFormat.percent(gpu),
                        detail: tr("аппаратное ускорение"),
                        color: .indigo,
                        points: model.displayedHistory,
                        yValue: { $0.gpuPercent ?? 0 }
                    )
                }

                MetricHistoryCard(
                    title: tr("Память"),
                    value: MetricFormat.bytes(model.snapshot.memory.usedBytes),
                    detail: memoryDetail,
                    color: .blue,
                    points: model.displayedHistory,
                    yValue: { Double($0.memoryUsedBytes) }
                )

                MetricHistoryCard(
                    title: tr("Сеть"),
                    value: "↓ \(MetricFormat.compactRate(model.snapshot.network.downloadBytesPerSecond))",
                    detail: "↑ \(MetricFormat.compactRate(model.snapshot.network.uploadBytesPerSecond))",
                    color: .teal,
                    points: model.displayedHistory,
                    yValue: { $0.networkDownloadBytesPerSecond + $0.networkUploadBytesPerSecond }
                )

                MetricHistoryCard(
                    title: tr("Диск"),
                    value: tr("чтение %@", String(describing: MetricFormat.compactRate(model.snapshot.disk.downloadBytesPerSecond))),
                    detail: tr("запись %@", String(describing: MetricFormat.compactRate(model.snapshot.disk.uploadBytesPerSecond))),
                    color: .orange,
                    points: model.displayedHistory,
                    yValue: { $0.diskReadBytesPerSecond + $0.diskWriteBytesPerSecond }
                )

                HStack(alignment: .top, spacing: 12) {
                    ConsumerList(
                        title: tr("Больше всего процессора"),
                        samples: Array(model.snapshot.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(6)),
                        isLive: true,
                        onProcessActionCompleted: { model.requestImmediateProcessRefresh() },
                        value: { MetricFormat.processCPU($0, totalCores: model.snapshot.coreCount) }
                    )
                    ConsumerList(
                        title: tr("Больше всего памяти"),
                        samples: Array(model.snapshot.processes.sorted { $0.residentBytes > $1.residentBytes }.prefix(6)),
                        isLive: true,
                        onProcessActionCompleted: { model.requestImmediateProcessRefresh() },
                        value: { MetricFormat.bytes($0.residentBytes) }
                    )
                }
            }
            .padding(18)
        }
    }
}

private struct UsageDashboard: View {
    @ObservedObject var model: AppModel

    private var shownBatterySession: BatterySessionRecord? {
        model.usageReport.currentBatterySession ?? model.usageReport.latestBatterySession
    }

    private var maximumHours: Double {
        max(model.usageReport.daily.map { $0.awakeSeconds / 3_600 }.max() ?? 0, 1)
    }

    private var ledgerItems: [LedgerItem] {
        var items = [
            LedgerItem(
                title: tr("Сегодня без сна"),
                value: MetricFormat.duration(model.usageReport.todayAwakeSeconds),
                subtitle: tr("сон и выключение не входят")
            )
        ]
        if model.hasInternalBattery {
            items.append(
                LedgerItem(
                    title: model.usageReport.currentBatterySession == nil ? tr("Последний разряд") : tr("Этот разряд"),
                    value: shownBatterySession.map { MetricFormat.duration($0.awakeSeconds) } ?? "—",
                    subtitle: batterySessionSubtitle
                )
            )
            items.append(
                LedgerItem(
                    title: tr("Оценка 0–100%"),
                    value: model.usageReport.fullChargeEstimate.map { "≈ " + MetricFormat.duration($0.seconds) } ?? "—",
                    subtitle: estimateSubtitle
                )
            )
        }
        return items
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let error = model.historyError {
                    UsageUnavailableCard(message: error)
                } else {
                    LedgerStripCard(items: ledgerItems)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr("Последние 7 дней"))
                                    .font(.system(size: 14, weight: .semibold))
                                Text(model.hasInternalBattery
                                    ? tr("Фактическое бодрствование и его часть от батареи")
                                    : tr("Фактическое время работы без сна и выключений"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.hasInternalBattery {
                                HStack(spacing: 12) {
                                    UsageLegend(label: tr("Всего"), color: .blue)
                                    UsageLegend(label: tr("От батареи"), color: .teal)
                                }
                            }
                        }

                        Chart(model.usageReport.daily) { point in
                            if model.hasInternalBattery {
                                BarMark(
                                    x: .value(tr("День"), point.day, unit: .day),
                                    y: .value(tr("Часы"), point.awakeSeconds / 3_600)
                                )
                                .position(by: .value(tr("Тип"), tr("Всего")))
                                .foregroundStyle(.blue.opacity(0.85))
                                .cornerRadius(3)

                                BarMark(
                                    x: .value(tr("День"), point.day, unit: .day),
                                    y: .value(tr("Часы"), point.batteryAwakeSeconds / 3_600)
                                )
                                .position(by: .value(tr("Тип"), tr("От батареи")))
                                .foregroundStyle(.teal.opacity(0.85))
                                .cornerRadius(3)
                            } else {
                                BarMark(
                                    x: .value(tr("День"), point.day, unit: .day),
                                    y: .value(tr("Часы"), point.awakeSeconds / 3_600)
                                )
                                .foregroundStyle(.blue.opacity(0.85))
                                .cornerRadius(3)
                            }
                        }
                        .chartYScale(domain: 0...(maximumHours * 1.15))
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                                AxisValueLabel {
                                    if let hours = value.as(Double.self) {
                                        Text(tr("%@ ч", String(describing: hours.formatted(.number.precision(.fractionLength(0...1))))))
                                            .font(.caption2)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day)) { _ in
                                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                            }
                        }
                        .frame(height: 270)
                    }
                    .cardStyle()

                    Label(
                        tr("Учёт начинается с первого запуска PurrCore на этом Mac. Разрывы наблюдения длиннее 5 секунд считаются сном, выключением или временем без приложения и не добавляются."),
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle(padding: 12)
                }
            }
            .padding(18)
        }
    }

    private var batterySessionSubtitle: String {
        guard let session = shownBatterySession else { return tr("данные появятся после работы от батареи") }
        let percentRange = "\(Int(session.startPercent.rounded())) → \(Int(session.endPercent.rounded()))%"
        if model.usageReport.currentBatterySession != nil {
            return session.startBoundaryKnown
                ? tr("%@ · с отключения от сети", String(describing: percentRange))
                : tr("%@ · с запуска наблюдения", String(describing: percentRange))
        }
        return tr("%@ · завершённая сессия", String(describing: percentRange))
    }

    private var estimateSubtitle: String {
        guard let estimate = model.usageReport.fullChargeEstimate else {
            return tr("появится после 2 наблюдаемых разрядов")
        }
        return tr("по %@ последним разрядам", String(describing: estimate.sessionCount))
    }
}

private struct UsageOverviewCard: View {
    let report: UsageReport
    let showBattery: Bool

    private var batterySession: BatterySessionRecord? {
        report.currentBatterySession ?? report.latestBatterySession
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tr("Время работы"), systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Text(tr("сон и выключение исключены"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                UsageOverviewValue(
                    label: tr("Сегодня"),
                    value: MetricFormat.duration(report.todayAwakeSeconds)
                )
                if showBattery {
                    UsageOverviewValue(
                        label: report.currentBatterySession == nil ? tr("Последний разряд") : tr("Этот разряд"),
                        value: batterySession.map { MetricFormat.duration($0.awakeSeconds) } ?? "—"
                    )
                    UsageOverviewValue(
                        label: "0–100%",
                        value: report.fullChargeEstimate.map { "≈ " + MetricFormat.duration($0.seconds) } ?? "—"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct UsageUnavailableCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(tr("Учёт времени недоступен"), systemImage: "exclamationmark.triangle")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct UsageOverviewValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageLegend: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProcessorDashboard: View {
    @ObservedObject var model: AppModel
    @State private var scope: ProcessScope = .live

    private var displayedProcesses: [ProcessGroupSample] {
        switch scope {
        case .live:
            model.snapshot.processes.sorted { $0.cpuPercent > $1.cpuPercent }
        case .history:
            model.historicalCPUProcessGroups
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Общая загрузка"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(MetricFormat.percent(model.snapshot.cpuPercent))
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                        Text(tr("Кошка ускоряется вместе с этой величиной · доля от всего Mac"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(tr("Загрузка по ядрам"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        CoreLoadStrip(
                            perCoreCPU: model.snapshot.perCoreCPU,
                            coreClusters: model.snapshot.coreClusters,
                            coreCount: model.snapshot.coreCount,
                            compact: false
                        )
                    }
                }
                .cardStyle()

                LargeHistoryChart(
                    points: model.displayedHistory,
                    color: .blue,
                    yValue: { $0.cpuPercent },
                    yFormat: { MetricFormat.axisPercent($0) },
                    yDomain: 0...100
                )

                ConsumerList(
                    title: tr("Понятные группы процессов"),
                    subtitle: scope == .history
                        ? tr("Средняя доля CPU за выбранный период (%@)", tr(model.selectedRange.title))
                        : nil,
                    emptyText: scope == .history
                        ? tr("За выбранный период пока нет сохранённых срезов процессов.")
                        : tr("Собираю подробный срез…"),
                    samples: displayedProcesses,
                    isLive: scope == .live,
                    onProcessActionCompleted: { model.requestImmediateProcessRefresh() },
                    value: { MetricFormat.processCPU($0, totalCores: model.snapshot.coreCount) },
                    headerAccessory: {
                        Picker(tr("Режим"), selection: $scope) {
                            ForEach(ProcessScope.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(width: 180)
                    }
                )
            }
            .padding(18)
        }
    }
}

private struct MemoryDashboard: View {
    @ObservedObject var model: AppModel
    @State private var scope: ProcessScope = .live

    private var displayedProcesses: [ProcessGroupSample] {
        switch scope {
        case .live:
            model.snapshot.processes.sorted { $0.residentBytes > $1.residentBytes }
        case .history:
            model.historicalMemoryProcessGroups
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("Использовано"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(MetricFormat.bytes(model.snapshot.memory.usedBytes))
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .monospacedDigit()
                                Text(tr("из %@", String(describing: MetricFormat.bytes(model.snapshot.memory.totalBytes))))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(MetricFormat.pressureColor(model.snapshot.memory.pressure))
                                .frame(width: 7, height: 7)
                            Text(tr("Давление: %@", String(describing: MetricFormat.pressure(model.snapshot.memory.pressure))))
                                .font(.callout.weight(.medium))
                                .foregroundStyle(
                                    model.snapshot.memory.pressure == .normal
                                        ? Color.secondary
                                        : MetricFormat.pressureColor(model.snapshot.memory.pressure)
                                )
                        }
                    }

                    MemoryBar(memory: model.snapshot.memory)
                        .frame(height: 8)

                    HStack(spacing: 0) {
                        MemoryLegend(label: tr("Приложения"), value: model.snapshot.memory.appBytes, color: .blue)
                        MemoryLegendDivider()
                        MemoryLegend(label: tr("Связанная"), value: model.snapshot.memory.wiredBytes, color: .orange)
                        MemoryLegendDivider()
                        MemoryLegend(label: tr("Сжатая"), value: model.snapshot.memory.compressedBytes, color: .teal)
                        MemoryLegendDivider()
                        MemoryLegend(label: tr("Кэш"), value: model.snapshot.memory.cachedBytes, color: .secondary)
                        MemoryLegendDivider()
                        MemoryLegend(label: "Swap", value: model.snapshot.memory.swapUsedBytes, color: model.snapshot.memory.swapUsedBytes > 0 ? .orange : .secondary)
                    }
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    }
                }
                .cardStyle()

                LargeHistoryChart(
                    title: tr("История памяти"),
                    points: model.displayedHistory,
                    color: .blue,
                    yValue: { Double($0.memoryUsedBytes) },
                    yFormat: { MetricFormat.shortBytes(UInt64(max($0, 0))) }
                )

                LargeHistoryChart(
                    title: tr("История Swap"),
                    trailingText: MetricFormat.bytes(model.snapshot.memory.swapUsedBytes),
                    points: model.displayedHistory,
                    color: .orange,
                    height: 165,
                    yValue: { Double($0.swapUsedBytes) },
                    yFormat: { MetricFormat.shortBytes(UInt64(max($0, 0))) }
                )

                ConsumerList(
                    title: tr("Кто занимает память"),
                    subtitle: scope == .history
                        ? tr("Пик физической памяти за выбранный период (%@)", tr(model.selectedRange.title))
                        : tr("Физическая память (как в Мониторинге системы)"),
                    emptyText: scope == .history
                        ? tr("За выбранный период пока нет сохранённых срезов процессов.")
                        : tr("Собираю подробный срез…"),
                    samples: displayedProcesses,
                    isLive: scope == .live,
                    onProcessActionCompleted: { model.requestImmediateProcessRefresh() },
                    value: { MetricFormat.bytes($0.residentBytes) },
                    headerAccessory: {
                        Picker(tr("Режим"), selection: $scope) {
                            ForEach(ProcessScope.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(width: 180)
                    }
                )
            }
            .padding(18)
        }
    }
}

private enum ThroughputKind {
    case network
    case disk
}

private struct ThroughputDashboard: View {
    @ObservedObject var model: AppModel
    let kind: ThroughputKind

    private var read: Double {
        kind == .network ? model.snapshot.network.downloadBytesPerSecond : model.snapshot.disk.downloadBytesPerSecond
    }

    private var write: Double {
        kind == .network ? model.snapshot.network.uploadBytesPerSecond : model.snapshot.disk.uploadBytesPerSecond
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LedgerStripCard(items: [
                    LedgerItem(
                        title: kind == .network ? tr("Получение") : tr("Чтение"),
                        value: MetricFormat.compactRate(read),
                        subtitle: tr("текущая скорость")
                    ),
                    LedgerItem(
                        title: kind == .network ? tr("Отправка") : tr("Запись"),
                        value: MetricFormat.compactRate(write),
                        subtitle: tr("текущая скорость")
                    )
                ])
                LargeHistoryChart(
                    points: model.displayedHistory,
                    color: kind == .network ? .teal : .orange,
                    yValue: { point in
                        kind == .network
                            ? point.networkDownloadBytesPerSecond + point.networkUploadBytesPerSecond
                            : point.diskReadBytesPerSecond + point.diskWriteBytesPerSecond
                    },
                    yFormat: { MetricFormat.compactRate($0) }
                )
            }
            .padding(18)
        }
    }
}

private struct TaskDashboard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tr("Метки задач"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(tr("PurrCore хранит только начало/конец задачи и её подпись. Содержимое MemPalace и команд не копируется."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                if model.taskMarkers.isEmpty {
                    ContentUnavailableView(
                        tr("Пока нет меток"),
                        systemImage: "flag",
                        description: Text(tr("Их можно добавить через purrcorectl из MemPalace или другого рабочего процесса."))
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.taskMarkers.reversed()) { marker in
                            TaskMarkerRow(marker: marker, history: model.displayedHistory)
                            if marker.id != model.taskMarkers.first?.id { Divider() }
                        }
                    }
                    .cardStyle(padding: 8)
                }
            }
            .padding(18)
        }
    }
}

private struct MetricHistoryCard<ExtraHeader: View>: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    let points: [HistoryPoint]
    let yValue: (HistoryPoint) -> Double
    let extraHeader: ExtraHeader

    init(
        title: String,
        value: String,
        detail: String,
        color: Color,
        points: [HistoryPoint],
        yValue: @escaping (HistoryPoint) -> Double,
        @ViewBuilder extraHeader: () -> ExtraHeader
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.color = color
        self.points = points
        self.yValue = yValue
        self.extraHeader = extraHeader()
    }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                extraHeader
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .frame(width: 256, alignment: .leading)

            CompactHistoryChart(points: points, color: color, yValue: yValue)
        }
        .frame(maxWidth: .infinity)
        .cardStyle(padding: 14)
    }
}

private extension MetricHistoryCard where ExtraHeader == EmptyView {
    init(
        title: String,
        value: String,
        detail: String,
        color: Color,
        points: [HistoryPoint],
        yValue: @escaping (HistoryPoint) -> Double
    ) {
        self.init(
            title: title,
            value: value,
            detail: detail,
            color: color,
            points: points,
            yValue: yValue,
            extraHeader: { EmptyView() }
        )
    }
}

private struct CompactHistoryChart: View {
    let points: [HistoryPoint]
    let color: Color
    let yValue: (HistoryPoint) -> Double

    var body: some View {
        Chart(points) { point in
            AreaMark(
                x: .value(tr("Время"), point.timestamp),
                y: .value(tr("Значение"), yValue(point))
            )
            .foregroundStyle(
                LinearGradient(colors: [color.opacity(0.24), color.opacity(0.01)], startPoint: .top, endPoint: .bottom)
            )
            LineMark(
                x: .value(tr("Время"), point.timestamp),
                y: .value(tr("Значение"), yValue(point))
            )
            .foregroundStyle(color)
            .lineStyle(.init(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 68)
    }
}

private struct LargeHistoryChart: View {
    var title: String? = nil
    var trailingText: String? = nil
    let points: [HistoryPoint]
    let color: Color
    var height: CGFloat = 250
    let yValue: (HistoryPoint) -> Double
    let yFormat: (Double) -> String
    var yDomain: ClosedRange<Double>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailingText != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Spacer()
                    if let trailingText {
                        Text(trailingText)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            chartBody
                .frame(height: height)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var chartBody: some View {
        let baseChart = Chart(points) { point in
            AreaMark(
                x: .value(tr("Время"), point.timestamp),
                y: .value(tr("Значение"), yValue(point))
            )
            .foregroundStyle(
                LinearGradient(colors: [color.opacity(0.22), color.opacity(0.01)], startPoint: .top, endPoint: .bottom)
            )
            LineMark(
                x: .value(tr("Время"), point.timestamp),
                y: .value(tr("Значение"), yValue(point))
            )
            .foregroundStyle(color)
            .lineStyle(.init(lineWidth: 1.8))
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(yFormat(number))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
            }
        }

        if let yDomain {
            baseChart.chartYScale(domain: yDomain)
        } else {
            baseChart
        }
    }
}

private struct ConsumerList<HeaderAccessory: View>: View {
    let title: String
    var subtitle: String? = nil
    var emptyText: String = tr("Собираю подробный срез…")
    let samples: [ProcessGroupSample]
    var isLive: Bool = false
    var onProcessActionCompleted: (() -> Void)? = nil
    let value: (ProcessGroupSample) -> String
    let headerAccessory: HeaderAccessory

    init(
        title: String,
        subtitle: String? = nil,
        emptyText: String = tr("Собираю подробный срез…"),
        samples: [ProcessGroupSample],
        isLive: Bool = false,
        onProcessActionCompleted: (() -> Void)? = nil,
        value: @escaping (ProcessGroupSample) -> String,
        @ViewBuilder headerAccessory: () -> HeaderAccessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.emptyText = emptyText
        self.samples = samples
        self.isLive = isLive
        self.onProcessActionCompleted = onProcessActionCompleted
        self.value = value
        self.headerAccessory = headerAccessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                headerAccessory
            }
            if samples.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 2) {
                    ForEach(samples) { sample in
                        DashboardConsumerRow(
                            sample: sample,
                            formattedValue: value(sample),
                            isLive: isLive,
                            onProcessActionCompleted: onProcessActionCompleted
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct DashboardConsumerRow: View {
    let sample: ProcessGroupSample
    let formattedValue: String
    let isLive: Bool
    let onProcessActionCompleted: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: sample.category.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(sample.category.color.opacity(0.85))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(tr(sample.displayName))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(tr(sample.explanation) + (sample.processCount > 1 ? tr(" · %@ процессов", String(describing: sample.processCount)) : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if isLive {
                Menu {
                    ProcessActionMenuItems(process: sample, onCompleted: onProcessActionCompleted)
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
            }

            Text(formattedValue)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered && isLive ? Color.primary.opacity(0.045) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            if isLive {
                ProcessActionMenuItems(process: sample, onCompleted: onProcessActionCompleted)
            }
        }
    }
}

private extension ConsumerList where HeaderAccessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        emptyText: String = tr("Собираю подробный срез…"),
        samples: [ProcessGroupSample],
        isLive: Bool = false,
        onProcessActionCompleted: (() -> Void)? = nil,
        value: @escaping (ProcessGroupSample) -> String
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            emptyText: emptyText,
            samples: samples,
            isLive: isLive,
            onProcessActionCompleted: onProcessActionCompleted,
            value: value,
            headerAccessory: { EmptyView() }
        )
    }
}

private struct MemoryLegendDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(width: 1)
    }
}

private struct MemoryLegend: View {
    let label: String
    let value: UInt64
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(MetricFormat.bytes(value))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TaskMarkerRow: View {
    let marker: TaskMarker
    let history: [HistoryPoint]

    private var nearestPoint: HistoryPoint? {
        history.min {
            abs($0.timestamp.timeIntervalSince(marker.timestamp)) < abs($1.timestamp.timeIntervalSince(marker.timestamp))
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: marker.kind == .begin ? "play.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(marker.kind == .begin ? .blue : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(marker.label)
                    .font(.system(size: 13, weight: .medium))
                Text("\(marker.source) · \(marker.timestamp.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let nearestPoint {
                Text("CPU \(MetricFormat.percent(nearestPoint.cpuPercent))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(MetricFormat.bytes(nearestPoint.memoryUsedBytes))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }
        }
        .padding(10)
    }
}

private extension View {
    func cardStyle(padding: CGFloat = 15) -> some View {
        self
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}
