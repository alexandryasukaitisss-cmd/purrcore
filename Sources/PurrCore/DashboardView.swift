import Charts
import PurrCoreCore
import SwiftUI

private enum DashboardSection: String, CaseIterable, Identifiable {
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

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var selection: DashboardSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(DashboardSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .navigationTitle("PurrCore")
            .navigationSplitViewColumnWidth(min: 175, ideal: 205, max: 230)
        } detail: {
            VStack(spacing: 0) {
                dashboardToolbar
                Divider()
                detail(for: selection ?? .overview)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 880, minHeight: 600)
    }

    private var dashboardToolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text((selection ?? .overview).title)
                    .font(.title2.weight(.semibold))
                Text(tr("История хранится локально 7 дней"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker(tr("Период"), selection: $model.selectedRange) {
                ForEach(HistoryRange.allCases) { range in
                    Text(tr(range.title)).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
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

private struct OverviewDashboard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let error = model.historyError {
                    UsageUnavailableCard(message: error)
                } else {
                    UsageOverviewCard(report: model.usageReport)
                }
                MetricHistoryCard(
                    title: tr("Процессор"),
                    value: MetricFormat.percent(model.snapshot.cpuPercent),
                    detail: tr("общая загрузка"),
                    color: .blue,
                    points: model.displayedHistory,
                    yValue: { $0.cpuPercent }
                )
                MetricHistoryCard(
                    title: tr("Память"),
                    value: MetricFormat.bytes(model.snapshot.memory.usedBytes),
                    detail: tr("из %@ · давление %@", String(describing: MetricFormat.bytes(model.snapshot.memory.totalBytes)), String(describing: MetricFormat.pressure(model.snapshot.memory.pressure))),
                    color: .purple,
                    points: model.displayedHistory,
                    yValue: { Double($0.memoryUsedBytes) }
                )
                MetricHistoryCard(
                    title: tr("Сеть"),
                    value: "↓ \(MetricFormat.rate(model.snapshot.network.downloadBytesPerSecond))",
                    detail: "↑ \(MetricFormat.rate(model.snapshot.network.uploadBytesPerSecond))",
                    color: .green,
                    points: model.displayedHistory,
                    yValue: { $0.networkDownloadBytesPerSecond + $0.networkUploadBytesPerSecond }
                )
                MetricHistoryCard(
                    title: tr("Диск"),
                    value: tr("чтение %@", String(describing: MetricFormat.rate(model.snapshot.disk.downloadBytesPerSecond))),
                    detail: tr("запись %@", String(describing: MetricFormat.rate(model.snapshot.disk.uploadBytesPerSecond))),
                    color: .orange,
                    points: model.displayedHistory,
                    yValue: { $0.diskReadBytesPerSecond + $0.diskWriteBytesPerSecond }
                )

                HStack(alignment: .top, spacing: 14) {
                    ConsumerList(
                        title: tr("Больше всего процессора"),
                        samples: Array(model.snapshot.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(6)),
                        value: { MetricFormat.percent($0.cpuPercent) }
                    )
                    ConsumerList(
                        title: tr("Больше всего памяти"),
                        samples: Array(model.snapshot.processes.sorted { $0.residentBytes > $1.residentBytes }.prefix(6)),
                        value: { MetricFormat.bytes($0.residentBytes) }
                    )
                }

                if let error = model.historyError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let error = model.historyError {
                    UsageUnavailableCard(message: error)
                } else {
                    HStack(spacing: 14) {
                        HeroMetric(
                            title: tr("Сегодня без сна"),
                            value: MetricFormat.duration(model.usageReport.todayAwakeSeconds),
                            subtitle: tr("сон и выключение не входят"),
                            color: .blue
                        )
                        HeroMetric(
                            title: model.usageReport.currentBatterySession == nil ? tr("Последний разряд") : tr("Этот разряд"),
                            value: shownBatterySession.map { MetricFormat.duration($0.awakeSeconds) } ?? "—",
                            subtitle: batterySessionSubtitle,
                            color: .green
                        )
                        HeroMetric(
                            title: tr("Оценка 0–100%"),
                            value: model.usageReport.fullChargeEstimate.map { "≈ " + MetricFormat.duration($0.seconds) } ?? "—",
                            subtitle: estimateSubtitle,
                            color: .orange
                        )
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tr("Последние 7 дней"))
                                    .font(.headline)
                                Text(tr("Фактическое бодрствование и его часть от батареи"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 12) {
                                UsageLegend(label: tr("Всего"), color: .blue)
                                UsageLegend(label: tr("От батареи"), color: .green)
                            }
                        }

                        Chart(model.usageReport.daily) { point in
                            BarMark(
                                x: .value(tr("День"), point.day, unit: .day),
                                y: .value(tr("Часы"), point.awakeSeconds / 3_600)
                            )
                            .position(by: .value(tr("Тип"), tr("Всего")))
                            .foregroundStyle(.blue)
                            .cornerRadius(4)

                            BarMark(
                                x: .value(tr("День"), point.day, unit: .day),
                                y: .value(tr("Часы"), point.batteryAwakeSeconds / 3_600)
                            )
                            .position(by: .value(tr("Тип"), tr("От батареи")))
                            .foregroundStyle(.green)
                            .cornerRadius(4)
                        }
                        .chartYScale(domain: 0...(maximumHours * 1.15))
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                                AxisValueLabel {
                                    if let hours = value.as(Double.self) {
                                        Text(tr("%@ ч", String(describing: hours.formatted(.number.precision(.fractionLength(0...1))))))
                                    }
                                }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day)) { value in
                                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                            }
                        }
                        .frame(height: 280)
                    }
                    .cardStyle()

                    Label(
                        tr("Учёт начинается с первого запуска PurrCore на этом Mac. Разрывы наблюдения длиннее 5 секунд считаются сном, выключением или временем без приложения и не добавляются."),
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
                }
            }
            .padding(20)
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

    private var batterySession: BatterySessionRecord? {
        report.currentBatterySession ?? report.latestBatterySession
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(tr("Время работы"), systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Text(tr("сон и выключение исключены"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                UsageOverviewValue(
                    label: tr("Сегодня"),
                    value: MetricFormat.duration(report.todayAwakeSeconds),
                    color: .blue
                )
                UsageOverviewValue(
                    label: report.currentBatterySession == nil ? tr("Последний разряд") : tr("Этот разряд"),
                    value: batterySession.map { MetricFormat.duration($0.awakeSeconds) } ?? "—",
                    color: .green
                )
                UsageOverviewValue(
                    label: "0–100%",
                    value: report.fullChargeEstimate.map { "≈ " + MetricFormat.duration($0.seconds) } ?? "—",
                    color: .orange
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct UsageUnavailableCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tr("Учёт времени недоступен"), systemImage: "exclamationmark.triangle")
                .font(.headline)
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
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageLegend: View {
    let label: String
    let color: Color

    var body: some View {
        Label(label, systemImage: "circle.fill")
            .font(.caption)
            .foregroundStyle(color)
    }
}

private struct ProcessorDashboard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HeroMetric(
                    title: tr("Общая загрузка"),
                    value: MetricFormat.percent(model.snapshot.cpuPercent),
                    subtitle: tr("Кошка ускоряется вместе с этой величиной"),
                    color: .blue
                )
                LargeHistoryChart(points: model.displayedHistory, color: .blue, yValue: { $0.cpuPercent })
                ConsumerList(
                    title: tr("Понятные группы процессов"),
                    samples: model.snapshot.processes.sorted { $0.cpuPercent > $1.cpuPercent },
                    value: { MetricFormat.percent($0.cpuPercent) }
                )
            }
            .padding(20)
        }
    }
}

private struct MemoryDashboard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    HeroMetric(
                        title: tr("Использовано"),
                        value: MetricFormat.bytes(model.snapshot.memory.usedBytes),
                        subtitle: tr("из %@", String(describing: MetricFormat.bytes(model.snapshot.memory.totalBytes))),
                        color: .purple
                    )
                    Spacer()
                    Label(
                        tr("Давление: %@", String(describing: MetricFormat.pressure(model.snapshot.memory.pressure))),
                        systemImage: "circle.fill"
                    )
                    .foregroundStyle(MetricFormat.pressureColor(model.snapshot.memory.pressure))
                }
                .cardStyle()

                VStack(spacing: 14) {
                    MemoryBar(memory: model.snapshot.memory)
                        .frame(height: 12)
                    HStack {
                        MemoryLegend(label: tr("Приложения"), value: model.snapshot.memory.appBytes, color: .purple)
                        MemoryLegend(label: tr("Связанная"), value: model.snapshot.memory.wiredBytes, color: .orange)
                        MemoryLegend(label: tr("Сжатая"), value: model.snapshot.memory.compressedBytes, color: .cyan)
                        MemoryLegend(label: tr("Кэш"), value: model.snapshot.memory.cachedBytes, color: .secondary)
                        MemoryLegend(label: "Swap", value: model.snapshot.memory.swapUsedBytes, color: .pink)
                    }
                }
                .cardStyle()

                LargeHistoryChart(points: model.displayedHistory, color: .purple, yValue: { Double($0.memoryUsedBytes) })
                ConsumerList(
                    title: tr("Кто занимает память"),
                    samples: model.snapshot.processes.sorted { $0.residentBytes > $1.residentBytes },
                    value: { MetricFormat.bytes($0.residentBytes) }
                )
            }
            .padding(20)
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
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    HeroMetric(
                        title: kind == .network ? tr("Получение") : tr("Чтение"),
                        value: MetricFormat.rate(read),
                        subtitle: tr("текущая скорость"),
                        color: kind == .network ? .green : .orange
                    )
                    HeroMetric(
                        title: kind == .network ? tr("Отправка") : tr("Запись"),
                        value: MetricFormat.rate(write),
                        subtitle: tr("текущая скорость"),
                        color: .cyan
                    )
                }
                LargeHistoryChart(
                    points: model.displayedHistory,
                    color: kind == .network ? .green : .orange,
                    yValue: { point in
                        kind == .network
                            ? point.networkDownloadBytesPerSecond + point.networkUploadBytesPerSecond
                            : point.diskReadBytesPerSecond + point.diskWriteBytesPerSecond
                    }
                )
            }
            .padding(20)
        }
    }
}

private struct TaskDashboard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Метки задач"))
                        .font(.title3.weight(.semibold))
                    Text(tr("PurrCore хранит только начало/конец задачи и её подпись. Содержимое MemPalace и команд не копируется."))
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
                    .frame(maxWidth: .infinity, minHeight: 300)
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
            .padding(20)
        }
    }
}

private struct MetricHistoryCard: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    let points: [HistoryPoint]
    let yValue: (HistoryPoint) -> Double

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 205, alignment: .leading)

            CompactHistoryChart(points: points, color: color, yValue: yValue)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
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
                LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
            )
            LineMark(
                x: .value(tr("Время"), point.timestamp),
                y: .value(tr("Значение"), yValue(point))
            )
            .foregroundStyle(color)
            .lineStyle(.init(lineWidth: 1.6))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 76)
    }
}

private struct LargeHistoryChart: View {
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
                LinearGradient(colors: [color.opacity(0.28), color.opacity(0.015)], startPoint: .top, endPoint: .bottom)
            )
            LineMark(
                x: .value(tr("Время"), point.timestamp),
                y: .value(tr("Значение"), yValue(point))
            )
            .foregroundStyle(color)
            .lineStyle(.init(lineWidth: 2))
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel()
            }
        }
        .frame(height: 280)
        .cardStyle()
    }
}

private struct HeroMetric: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct ConsumerList: View {
    let title: String
    let samples: [ProcessGroupSample]
    let value: (ProcessGroupSample) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.headline)
            if samples.isEmpty {
                Text(tr("Собираю подробный срез…"))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            } else {
                ForEach(samples) { sample in
                    HStack(spacing: 9) {
                        Image(systemName: sample.category.symbol)
                            .foregroundStyle(sample.category.color)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr(sample.displayName))
                                .lineLimit(1)
                            Text(tr(sample.explanation) + (sample.processCount > 1 ? tr(" · %@ процессов", String(describing: sample.processCount)) : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(value(sample))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

private struct MemoryLegend: View {
    let label: String
    let value: UInt64
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(color)
            Text(MetricFormat.bytes(value))
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
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
                Text("\(marker.source) · \(marker.timestamp.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let nearestPoint {
                Text("CPU \(MetricFormat.percent(nearestPoint.cpuPercent))")
                    .monospacedDigit()
                Text(MetricFormat.bytes(nearestPoint.memoryUsedBytes))
                    .monospacedDigit()
            }
        }
        .padding(10)
    }
}

private extension View {
    func cardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}
