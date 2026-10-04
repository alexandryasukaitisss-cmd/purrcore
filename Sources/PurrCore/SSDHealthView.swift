import PurrCoreCore
import SwiftUI

struct SSDHealthSummary: View {
    let snapshot: SSDHealthSnapshot?
    var isExternal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(isExternal ? tr("Физическое здоровье") : tr("Здоровье SSD"), systemImage: "externaldrive.fill.badge.checkmark")
                    .font(.headline)
                Spacer()
                statusBadge
            }

            if let snapshot {
                if snapshot.model != nil || snapshot.capacityBytes != nil {
                    VStack(alignment: .leading, spacing: 3) {
                        if let model = snapshot.model {
                            Text(model)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            if let capacity = snapshot.capacityBytes {
                                Text(MetricFormat.bytes(capacity))
                            }
                            if let protocolName = snapshot.protocolName {
                                Text("·")
                                Text(protocolName)
                            }
                            if let mediaType = snapshot.mediaType {
                                Text("·")
                                Text(mediaType)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 16) {
                    if let temperature = snapshot.temperatureC {
                        metric(tr("Температура"), "\(temperature.formatted(.number.precision(.fractionLength(0)))) °C")
                    }
                    if let used = snapshot.percentageUsed {
                        metric(tr("Износ"), MetricFormat.percent(used))
                    }
                    if let spare = snapshot.availableSparePercent {
                        metric(tr("Резерв"), MetricFormat.percent(spare))
                    }
                }
            } else {
                Text(tr("Данные SMART пока недоступны"))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var statusBadge: some View {
        let status = snapshot?.status ?? .unavailable
        return HStack(spacing: 5) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 7, height: 7)
            Text(isExternal && status == .unavailable ? tr("Неизвестно") : statusName(status))
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(statusColor(status))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
    }

    fileprivate func statusName(_ status: SSDHealthStatus) -> String {
        switch status {
        case .healthy: tr("Норма")
        case .warning: tr("Внимание")
        case .critical: tr("Критично")
        case .unavailable: tr("Нет данных")
        }
    }

    fileprivate func statusColor(_ status: SSDHealthStatus) -> Color {
        switch status {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        case .unavailable: .secondary
        }
    }
}

struct SSDHealthView: View {
    @ObservedObject var model: AppModel
    @State private var selectedDiskID = "system"

    private var externalDisk: ExternalSSDHealthReport? {
        model.externalSSDHealth.first { $0.id == selectedDiskID }
    }

    private var selectedSnapshot: SSDHealthSnapshot? {
        selectedDiskID == "system" ? model.ssdHealth : externalDisk?.health
    }

    private var selectedError: String? {
        selectedDiskID == "system" ? model.ssdHealthError : model.externalSSDHealthError
    }

    private let summaryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Здоровье SSD"))
                            .font(.title2.weight(.semibold))
                        Text(tr("Только чтение SMART и системной информации"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(tr("Обновить")) { model.refreshSSDHealth() }
                        .disabled(model.ssdHealthLoading)
                }

                Picker(tr("Накопитель"), selection: $selectedDiskID) {
                    Text(tr("Встроенный SSD")).tag("system")
                    ForEach(model.externalSSDHealth) { disk in
                        Text(tr("%@ · внешний", String(describing: disk.displayName))).tag(disk.id)
                    }
                    if selectedDiskID != "system", externalDisk == nil {
                        Text(tr("Выбранный внешний накопитель недоступен")).tag(selectedDiskID)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("ssd-device-picker")

                if selectedDiskID == "system", model.externalSSDHealth.isEmpty, !model.ssdHealthLoading {
                    Text(model.externalSSDHealthError == nil
                         ? tr("Доступных внешних накопителей не найдено. Подключите SSD и обновите список.")
                         : tr("Не удалось обновить список внешних накопителей: %@", String(describing: model.externalSSDHealthError!)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let snapshot = selectedSnapshot {
                    SSDHealthSummary(snapshot: snapshot, isExternal: selectedDiskID != "system")
                }

                if model.ssdHealthLoading {
                    ProgressView(tr("Читаю данные диска…"))
                        .controlSize(.small)
                }

                if let error = selectedError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                if selectedDiskID != "system", externalDisk == nil, !model.ssdHealthLoading {
                    ContentUnavailableView(tr("Накопитель недоступен"), systemImage: "externaldrive.badge.xmark",
                        description: Text(tr("Он отключён или список не удалось прочитать. Подключите его и выберите снова; прежние показатели больше не используются.")))
                }

                if let disk = externalDisk {
                    externalAnalysis(disk)
                }

                if let snapshot = selectedSnapshot {
                    if selectedDiskID == "system" {
                        metrics(snapshot)
                    } else if snapshot.status != .unavailable {
                        externalHealthMetrics(snapshot)
                    }
                    if selectedDiskID == "system", snapshot.status == .unavailable {
                        Text(tr("macOS не предоставила SMART-статус или метрики для этого диска."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(tr("Обновлено %@", String(describing: summaryFormatter.string(from: snapshot.timestamp))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(tr("SMART — индикатор, а не замена резервным копиям"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 430)
        .onAppear { model.refreshSSDHealth() }
    }

    private func externalAnalysis(_ disk: ExternalSSDHealthReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(disk.displayName).font(.headline)
                Text(externalHealthExplanation(disk.health))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if disk.health.status == .unavailable {
                    Text(tr("Температура, износ NAND, резерв, внутренние ошибки носителя и аварийные отключения питания недоступны. Свободное место и USB-соединение не подтверждают здоровье SSD."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(tr("ПОДКЛЮЧЕНИЕ И ДОСТУП"))
                metricRow(tr("Интерфейс"), disk.health.protocolName)
                metricRow(tr("Скорость USB-соединения"), disk.usbLinkMbps.map {
                    $0 >= 1_000 ? tr("%@ Гбит/с", String(describing: ($0 / 1_000).formatted())) : tr("%@ Мбит/с", String(describing: $0.formatted()))
                })
                metricRow(tr("Режим носителя"), disk.isWritable.map { $0 ? tr("Чтение и запись") : tr("Только чтение") })
                metricRow(tr("Подключённые тома"), tr("%@ из %@", String(describing: disk.volumes.filter { $0.mountPoint != nil }.count), String(describing: disk.volumes.count)))
                if disk.usbLinkMbps != nil {
                    Text(tr("Скорость соединения — предел интерфейса, а не измеренная скорость чтения или записи."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let speed = disk.usbLinkMbps, speed <= 480 {
                    Label(tr("Медленное USB-соединение. Проверьте кабель, порт и хаб."), systemImage: "cable.connector")
                        .font(.callout).foregroundStyle(.orange)
                }
                if disk.isWritable == false {
                    Text(tr("Носитель доступен только для чтения. Само по себе это не доказывает износ или поломку."))
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(tr("ОБМЕН ДАННЫМИ БЕЗ SMART"))
                if let io = disk.ioStatistics {
                    Label(io.hasIssues ? tr("Зафиксированы ошибки или повторные попытки") : (io.hasCompleteErrorCounters ? tr("Ошибок и повторных попыток не обнаружено") : tr("Доступны отдельные счётчики обмена")),
                          systemImage: io.hasIssues ? "exclamationmark.triangle" : "arrow.left.arrow.right")
                        .font(.callout).foregroundStyle(io.hasIssues ? Color.orange : Color.primary)
                    metricRow(tr("Ошибки чтения"), io.readErrors.map { $0.formatted() })
                    metricRow(tr("Ошибки записи"), io.writeErrors.map { $0.formatted() })
                    metricRow(tr("Повторы чтения"), io.readRetries.map { $0.formatted() })
                    metricRow(tr("Повторы записи"), io.writeRetries.map { $0.formatted() })
                    metricRow(tr("Прочитано"), io.bytesRead.map(MetricFormat.bytes))
                    metricRow(tr("Записано"), io.bytesWritten.map(MetricFormat.bytes))
                    Text(tr("Счётчики macOS за текущий период работы драйвера; могут сброситься при переподключении или перезагрузке. Это обмен через интерфейс, а не запись в NAND за весь срок службы. Нули не гарантируют исправность SSD."))
                        .font(.caption).foregroundStyle(.secondary)
                    if io.hasIssues {
                        Text(tr("Причиной может быть накопитель, кабель, порт или хаб. Сохраните важные данные и проверьте подключение; эти счётчики не определяют источник сбоя."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text(tr("macOS не предоставила счётчики обмена для этого устройства."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(tr("МЕСТО ДЛЯ РАБОТЫ"))
                if let storage = disk.storage {
                    metricRow(tr("Свободно"), "\(MetricFormat.bytes(storage.freeBytes)) · \(MetricFormat.percent((1 - storage.usedFraction) * 100))")
                    metricRow(tr("Занято"), "\(MetricFormat.bytes(storage.usedBytes)) / \(MetricFormat.bytes(storage.totalBytes))")
                    ProgressView(value: storage.usedFraction).tint(storage.usedFraction >= 0.9 ? .orange : .blue)
                    if storage.usedFraction >= 0.9 {
                        Text(tr("Свободно не больше 10%. Освободите место перед большими копированиями; это оценка заполнения, а не износа NAND."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text(tr("Объём свободного места не предоставлен. Для нескольких физических дисков в одном контейнере общий объём не приписывается этому SSD."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(disk.volumes) { volume in
                    VStack(alignment: .leading, spacing: 3) {
                        metricRow(volume.name, volume.mountPoint == nil ? tr("Не смонтирован") : volume.isWritable.map { $0 ? tr("Чтение и запись") : tr("Только чтение") })
                        if let path = volume.mountPoint {
                            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                if disk.volumes.count > 1 {
                    Text(tr("APFS-тома одного контейнера делят свободное место: оно учитывается один раз."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text(tr("Перед отсоединением извлеките все тома накопителя в Finder и дождитесь завершения операций. Аварийные отключения питания, если доступны, — накопленный счётчик, а не число поломок."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func externalHealthExplanation(_ health: SSDHealthSnapshot) -> String {
        switch health.status {
        case .unavailable:
            tr("macOS и контроллер этого подключения не предоставили данные SMART. Физическое здоровье пока нельзя оценить.")
        case .critical:
            tr("SMART сообщает о критическом состоянии. Сохраните резервную копию важных данных и проверьте накопитель.")
        case .warning:
            tr("Есть предупреждение SMART: проверьте температуру, износ и резерв ниже. Сохраните резервную копию.")
        case .healthy:
            tr("В доступных данных SMART критических признаков нет. Для съёмного SSD особенно важны ошибки носителя, износ и аварийные отключения питания.")
        }
    }

    private func externalHealthMetrics(_ snapshot: SSDHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(tr("SMART СЪЁМНОГО SSD"))
            metricRow(tr("Статус SMART"), snapshot.smartStatus.map { $0 ? "OK" : tr("Сбой") })
            metricRow(tr("Ошибки носителя"), snapshot.mediaErrors.map(String.init))
            metricRow(tr("Аварийные отключения питания"), snapshot.unsafeShutdowns.map(String.init))
            metricRow(tr("Температура"), snapshot.temperatureC.map { "\($0.formatted(.number.precision(.fractionLength(1)))) °C" })
            metricRow(tr("Износ NAND"), snapshot.percentageUsed.map { MetricFormat.percent($0) })
            metricRow(tr("Резерв / порог"), pair(snapshot.availableSparePercent, snapshot.spareThresholdPercent, suffix: "%"))
            metricRow(tr("Записано за срок службы"), snapshot.dataUnitsWrittenTB.map { "\($0.formatted(.number.precision(.fractionLength(2)))) TB" })
            metricRow(tr("Циклы питания"), snapshot.powerCycles.map(String.init))
            metricRow(tr("Часы работы"), snapshot.powerOnHours.map(String.init))
            metricRow(tr("Критическое предупреждение"), snapshot.criticalWarning.map(String.init))
            metricRow(tr("Записи журнала ошибок"), snapshot.errorLogEntries.map(String.init))
            Text(tr("«—» означает, что показатель не предоставлен; это не нулевое значение."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func metrics(_ snapshot: SSDHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("МЕТРИКИ"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            metricRow(tr("Критическое предупреждение"), snapshot.criticalWarning.map(String.init))
            metricRow(tr("Температура"), snapshot.temperatureC.map { "\($0.formatted(.number.precision(.fractionLength(1)))) °C" })
            metricRow(tr("Резерв"), pair(snapshot.availableSparePercent, snapshot.spareThresholdPercent, suffix: "%"))
            metricRow(tr("Износ"), snapshot.percentageUsed.map { MetricFormat.percent($0) })
            metricRow(tr("Прочитано"), snapshot.dataUnitsReadTB.map { "\($0.formatted(.number.precision(.fractionLength(2)))) TB" })
            metricRow(tr("Записано"), snapshot.dataUnitsWrittenTB.map { "\($0.formatted(.number.precision(.fractionLength(2)))) TB" })
            metricRow(tr("Циклы питания"), snapshot.powerCycles.map(String.init))
            metricRow(tr("Часы работы"), snapshot.powerOnHours.map(String.init))
            metricRow(tr("Аварийные выключения"), snapshot.unsafeShutdowns.map(String.init))
            metricRow(tr("Ошибки носителя"), snapshot.mediaErrors.map(String.init))
            metricRow(tr("Записи журнала ошибок"), snapshot.errorLogEntries.map(String.init))
        }
    }

    private func metricRow(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
    }

    private func pair(_ value: Double?, _ threshold: Double?, suffix: String) -> String? {
        guard let value else { return nil }
        let formatted = "\(value.formatted(.number.precision(.fractionLength(0))))\(suffix)"
        guard let threshold else { return formatted }
        return "\(formatted) / \(threshold.formatted(.number.precision(.fractionLength(0))))\(suffix)"
    }
}
