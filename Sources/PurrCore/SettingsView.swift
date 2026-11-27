import AppKit
import PurrCoreCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @AppStorage(AppDefaults.animationEnabled) private var animationEnabled = true
    @AppStorage(AppDefaults.restWhenIdle) private var restWhenIdle = true
    @AppStorage(AppDefaults.historyEnabled) private var historyEnabled = true
    @AppStorage(AppDefaults.statusMetric) private var statusMetric = StatusMetric.cpu.rawValue
    @AppStorage(AppDefaults.detailedProcessInterval) private var detailedProcessInterval = 5
    @AppStorage(AppDefaults.smartAlertsEnabled) private var smartAlertsEnabled = false
    @AppStorage(AppDefaults.autoCheckUpdates) private var autoCheckUpdates = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var suppressLaunchChange = false
    @State private var launchHint: String?
    @State private var batteryRetentionDays = 0
    @State private var pendingRetention: Int?
    @State private var confirmRetention = false
    @State private var customPetExpanded = false
    @State private var copiedCodexPrompt = false
    @State private var copiedBridgeCommand = false

    private let integrationCommand = tr("purrcorectl run --source mempalace --task-id TASK_ID --label \"Название задачи\" -- команда аргументы")

    private var availableMetrics: [StatusMetric] {
        StatusMetric.allCases.filter { metric in
            if metric == .gpu && model.snapshot.gpuPercent == nil {
                return false
            }
            return true
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(tr("Запускать при входе"), isOn: $launchAtLogin)
                    .accessibilityLabel(tr("Запускать при входе"))

                Toggle(tr("Проверять обновления по последнему коммиту на GitHub"), isOn: $autoCheckUpdates)

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Версия %@ · коммит %@", updater.localVersion, updater.localShortSHA))
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                        updateStatusLabel
                    }
                    Spacer()
                    if let candidate = updater.availableCandidate {
                        Button(tr("Обновить до %@ и перезапустить", candidate.shortSHA)) {
                            updater.installAvailableUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(updater.isBusy)
                    } else {
                        Button(tr("Проверить обновления")) {
                            updater.checkForUpdates(manual: true)
                        }
                        .controlSize(.small)
                        .disabled(updater.isBusy)
                    }
                }
            } header: {
                Text(tr("Запуск"))
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Для непрерывного учёта бодрствования PurrCore должен запускаться при входе в macOS."))
                    if let launchHint {
                        Text(launchHint)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                StatusItemPreview(model: model, metricRawValue: statusMetric, animationEnabled: animationEnabled)

                Picker(tr("Показатель рядом с питомцем"), selection: $statusMetric) {
                    ForEach(availableMetrics) { metric in
                        Text(tr(metric.title)).tag(metric.rawValue)
                    }
                }

                Toggle(tr("Анимировать бег"), isOn: $animationEnabled)
                    .accessibilityLabel(tr("Анимировать бег"))

                Toggle(tr("Дремать в простое (при нагрузке CPU < 3%)"), isOn: $restWhenIdle)
                    .disabled(!animationEnabled)

                DisclosureGroup(tr("Свой питомец по фото (через Codex)"), isExpanded: $customPetExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tr("Питомец может быть любым: кошка, собака, птица или кто-то ещё. Создай его бегущую анимацию по фото через Codex и импортируй готовые кадры."))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            if let photo = model.petPhoto {
                                Image(nsImage: photo)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .accessibilityLabel(tr("Фото-референс питомца"))
                            }
                            Button(model.petPhoto == nil ? tr("1. Выбрать фото…") : tr("1. Заменить фото…")) {
                                choosePetPhoto()
                            }
                            .controlSize(.small)
                            .disabled(model.importingPetAsset)

                            if model.importingPetAsset {
                                ProgressView().controlSize(.small)
                            }
                            if model.petPhoto != nil {
                                Button(tr("Показать фото")) { model.showPetReferenceInFinder() }
                                    .controlSize(.small)
                                Button(tr("Убрать фото")) { model.resetPetPhoto() }
                                    .controlSize(.small)
                                    .disabled(model.importingPetAsset)
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                copyCodexPrompt()
                            } label: {
                                if copiedCodexPrompt {
                                    Label(tr("2. Задание скопировано"), systemImage: "checkmark")
                                } else {
                                    Text(tr("2. Скопировать задание для Codex"))
                                }
                            }
                            .controlSize(.small)
                            .disabled(model.petPhoto == nil || model.importingPetAsset)

                            Button(model.petAnimation == nil ? tr("3. Импортировать кадры…") : tr("3. Заменить кадры…")) {
                                choosePetAnimation()
                            }
                            .controlSize(.small)
                            .disabled(model.importingPetAsset)

                            if model.petAnimation != nil {
                                Button(tr("Вернуть бегущую кошку")) { model.resetPetAnimation() }
                                    .controlSize(.small)
                                    .disabled(model.importingPetAsset)
                            }
                        }

                        Text(tr("Вставь задание в Codex на этом Mac. Затем выбери готовый PNG: 8 равных кадров в одном горизонтальном ряду, с прозрачным фоном. PurrCore хранит уменьшенную копию фото без метаданных и не отправляет её в интернет."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if let error = model.petPhotoError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                }
            } header: {
                Text(tr("Твой питомец в строке меню"))
            } footer: {
                Text(tr("При включённом системном «Уменьшении движения» питомец остаётся неподвижным."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker(tr("Подробный срез процессов"), selection: $detailedProcessInterval) {
                    Text(tr("каждые 5 секунд")).tag(5)
                    Text(tr("каждые 10 секунд")).tag(10)
                    Text(tr("каждые 15 секунд")).tag(15)
                }

                Toggle(tr("Хранить подробную историю ресурсов"), isOn: $historyEnabled)
                    .accessibilityLabel(tr("Хранить подробную историю ресурсов"))

                Toggle(tr("Умные уведомления о перегрузке, перегреве и нехватке места"), isOn: $smartAlertsEnabled)

                LabeledContent(tr("История ресурсов"), value: tr("7 дней"))

                LabeledContent(tr("Размер базы")) {
                    Text(MetricFormat.bytes(model.databaseSizeBytes))
                        .monospacedDigit()
                }

                if model.hasInternalBattery {
                    Picker(tr("История разрядов батареи"), selection: $batteryRetentionDays) {
                        Text(tr("Хранить без ограничения")).tag(0)
                        Text(tr("30 дней")).tag(30)
                        Text(tr("90 дней")).tag(90)
                        Text(tr("365 дней")).tag(365)
                    }
                }
            } header: {
                Text(tr("Мониторинг"))
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    if model.hasInternalBattery {
                        Text(tr("Срок применяется к завершённым разрядам. Текущий разряд сохраняется. Удаление старых разрядов может изменить оценку работы от полного заряда."))
                    }
                    Text(model.hasInternalBattery
                        ? tr("Учёт бодрствования и батареи хранится только на этом Mac. Между компьютерами ничего не синхронизируется.")
                        : tr("Учёт бодрствования хранится только на этом Mac. Между компьютерами ничего не синхронизируется."))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                SSDHealthSummary(snapshot: model.ssdHealth, embeddedInForm: true)

                if let error = model.ssdHealthError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button(tr("Все накопители…")) {
                        AppServices.shared.ssdHealthController.show(model: model)
                    }
                    .controlSize(.small)

                    if model.ssdHealthLoading {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Button(tr("Обновить")) { model.refreshSSDHealth() }
                        .controlSize(.small)
                        .disabled(model.ssdHealthLoading)
                }
            } header: {
                Text(tr("Здоровье SSD"))
            }

            Section {
                HStack(spacing: 10) {
                    Text(integrationCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button {
                        copyBridgeCommand()
                    } label: {
                        if copiedBridgeCommand {
                            Label(tr("Скопировано"), systemImage: "checkmark")
                        } else {
                            Text(tr("Скопировать"))
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            } header: {
                Text(tr("Необязательный мост MemPalace"))
            } footer: {
                Text(tr("Команда ставит отметки начала и конца задачи. PurrCore не читает содержимое памяти и не переносит туда сырые метрики."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 540)
        .onAppear {
            let current = SMAppService.mainApp.status == .enabled
            if launchAtLogin != current {
                suppressLaunchChange = true
                launchAtLogin = current
            }
            batteryRetentionDays = UserDefaults.standard.integer(forKey: AppDefaults.batteryRetentionDays)
            if model.petPhoto != nil || model.petAnimation != nil {
                customPetExpanded = true
            }
        }
        .onChange(of: restWhenIdle) { _, enabled in
            model.updateRestPreference(enabled: enabled)
        }
        .onChange(of: smartAlertsEnabled) { _, enabled in
            if enabled {
                SmartAlertNotifier.requestAuthorizationIfNeeded()
            }
        }
        .onChange(of: batteryRetentionDays) { _, days in
            guard days != UserDefaults.standard.integer(forKey: AppDefaults.batteryRetentionDays) else { return }
            if days == 0 {
                model.setBatteryRetention(days: 0)
            } else {
                pendingRetention = days
                confirmRetention = true
            }
        }
        .alert(tr("Удалять старые разряды?"), isPresented: $confirmRetention) {
            Button(tr("Отмена"), role: .cancel) {
                batteryRetentionDays = UserDefaults.standard.integer(forKey: AppDefaults.batteryRetentionDays)
                pendingRetention = nil
            }
            Button(tr("Применить и удалить"), role: .destructive) {
                if let days = pendingRetention { model.setBatteryRetention(days: days) }
                pendingRetention = nil
            }
        } message: {
            Text(tr("Завершённые разряды старше выбранного срока будут удалены, включая уже сохранённые. Это действие нельзя отменить."))
        }
        .onChange(of: launchAtLogin) { _, isEnabled in
            if suppressLaunchChange {
                suppressLaunchChange = false
                return
            }
            applyLaunchAtLogin(isEnabled)
        }
    }

    private func copyCodexPrompt() {
        guard let prompt = model.petGenerationPrompt else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(prompt, forType: .string) {
            copiedCodexPrompt = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                copiedCodexPrompt = false
            }
        }
    }

    private func copyBridgeCommand() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(integrationCommand, forType: .string) {
            copiedBridgeCommand = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                copiedBridgeCommand = false
            }
        }
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch updater.state {
        case .idle:
            Text(tr("Проверяет свежие коммиты в ветке main на GitHub."))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(tr("Проверяю последний коммит на GitHub…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .upToDate(let shortSHA):
            Text(tr("Установлена актуальная сборка (%@).", shortSHA))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .buildPending(let shortSHA):
            Text(tr("Новый коммит %@ сейчас собирается в GitHub Actions — попробуй через минуту.", shortSHA))
                .font(.caption)
                .foregroundStyle(.orange)
        case .available(let candidate):
            Text(candidate.commitTitle.isEmpty
                ? tr("На GitHub доступна новая сборка %@.", candidate.shortSHA)
                : tr("Новая сборка %@: %@", candidate.shortSHA, candidate.commitTitle))
                .font(.caption)
                .foregroundStyle(.blue)
                .lineLimit(2)
        case .installing(let progressText):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func choosePetPhoto() {
        let panel = NSOpenPanel()
        panel.title = tr("Фото твоего питомца")
        panel.message = tr("Выбери изображение до 20 МБ. Фото не отправляется в интернет.")
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.importPetPhoto(from: url)
        }
    }

    private func choosePetAnimation() {
        let panel = NSOpenPanel()
        panel.title = tr("Бегущая анимация питомца")
        panel.message = tr("PNG до 20 МБ: 8 кадров в одном горизонтальном ряду, прозрачный фон.")
        panel.allowedContentTypes = [.png]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.importPetAnimation(from: url)
        }
    }

    private func applyLaunchAtLogin(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    launchHint = tr("Подтверди доступ в Системных настройках → Основные → Объекты входа.")
                } else {
                    launchHint = nil
                }
            } else {
                try SMAppService.mainApp.unregister()
                launchHint = nil
            }
        } catch {
            let actual = SMAppService.mainApp.status == .enabled
            if launchAtLogin != actual {
                suppressLaunchChange = true
                launchAtLogin = actual
            }
            launchHint = error.localizedDescription
        }
    }
}

private struct StatusItemPreview: View {
    @ObservedObject var model: AppModel
    let metricRawValue: String
    let animationEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metricValue: String {
        (StatusMetric(rawValue: metricRawValue) ?? .cpu).menuBarValue(for: model.snapshot)
    }

    var body: some View {
        HStack {
            Text(tr("Предпросмотр строки меню"))
                .font(.system(size: 13))
            Spacer()
            HStack(spacing: 4) {
                AnimatedPetView(
                    cpuPercent: model.snapshot.cpuPercent,
                    animationEnabled: animationEnabled,
                    isResting: model.isPetResting,
                    reduceMotion: reduceMotion,
                    customFrames: model.petAnimation
                )
                .frame(width: CatAsset.menuBarSize.width, height: CatAsset.menuBarSize.height)

                if !metricValue.isEmpty {
                    Text(metricValue)
                        .font(Font(AppFonts.statusItemButton))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tr("Предпросмотр строки меню"))
        }
        .padding(.vertical, 2)
    }
}
