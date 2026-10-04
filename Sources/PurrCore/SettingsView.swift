import AppKit
import PurrCoreCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage(AppDefaults.animationEnabled) private var animationEnabled = true
    @AppStorage(AppDefaults.historyEnabled) private var historyEnabled = true
    @AppStorage(AppDefaults.statusMetric) private var statusMetric = StatusMetric.cpu.rawValue
    @AppStorage(AppDefaults.detailedProcessInterval) private var detailedProcessInterval = 5
    @State private var launchAtLogin = false
    @State private var launchHint: String?
    @State private var batteryRetentionDays = 0
    @State private var pendingRetention: Int?
    @State private var confirmRetention = false

    private let integrationCommand = tr("purrcorectl run --source mempalace --task-id TASK_ID --label \"Название задачи\" -- команда аргументы")

    var body: some View {
        Form {
            Section(tr("Запуск")) {
                Toggle(tr("Запускать при входе"), isOn: $launchAtLogin)
                    .accessibilityLabel(tr("Запускать при входе"))
                Text(tr("Для непрерывного учёта бодрствования PurrCore должен запускаться при входе в macOS."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let launchHint {
                    Text(launchHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(tr("Твой питомец в строке меню")) {
                StatusItemPreview(model: model, metricRawValue: statusMetric, animationEnabled: animationEnabled)
                Text(tr("Питомец может быть любым: кошка, собака, птица или кто-то ещё. Создай его бегущую анимацию по фото через Codex и импортируй готовые кадры."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if let photo = model.petPhoto {
                        Image(nsImage: photo).resizable().scaledToFit().frame(width: 48, height: 48)
                            .accessibilityLabel(tr("Фото-референс питомца"))
                    }
                    Button(model.petPhoto == nil ? tr("1. Выбрать фото…") : tr("1. Заменить фото…")) { choosePetPhoto() }
                        .disabled(model.importingPetAsset)
                    if model.importingPetAsset {
                        ProgressView().controlSize(.small)
                    }
                    if model.petPhoto != nil {
                        Button(tr("Убрать фото")) { model.resetPetPhoto() }
                            .disabled(model.importingPetAsset)
                    }
                }
                HStack {
                    Button(tr("2. Скопировать задание для Codex")) {
                        guard let prompt = model.petGenerationPrompt else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                    }
                    .disabled(model.petPhoto == nil || model.importingPetAsset)
                    if model.petPhoto != nil {
                        Button(tr("Показать фото")) { model.showPetReferenceInFinder() }
                    }
                }
                HStack {
                    Button(model.petAnimation == nil ? tr("3. Импортировать кадры…") : tr("3. Заменить кадры…")) { choosePetAnimation() }
                        .disabled(model.importingPetAsset)
                    if model.petAnimation != nil {
                        Button(tr("Вернуть бегущую кошку")) { model.resetPetAnimation() }
                            .disabled(model.importingPetAsset)
                    }
                }
                Text(tr("Вставь задание в Codex на этом Mac. Затем выбери готовый PNG: 8 равных кадров в одном горизонтальном ряду, с прозрачным фоном."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tr("PurrCore хранит уменьшенную копию фото без метаданных и не отправляет её в интернет. При генерации в Codex фото обрабатывает выбранный там сервис."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.petPhotoError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Toggle(tr("Анимировать бег"), isOn: $animationEnabled)
                    .accessibilityLabel(tr("Анимировать бег"))
                Picker(tr("Показатель рядом с питомцем"), selection: $statusMetric) {
                    ForEach(StatusMetric.allCases) { metric in
                        Text(tr(metric.title)).tag(metric.rawValue)
                    }
                }
                Text(tr("При включённом системном «Уменьшении движения» питомец остаётся неподвижным."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr("Мониторинг")) {
                Picker(tr("Подробный срез процессов"), selection: $detailedProcessInterval) {
                    Text(tr("каждые 5 секунд")).tag(5)
                    Text(tr("каждые 10 секунд")).tag(10)
                    Text(tr("каждые 15 секунд")).tag(15)
                }
                Toggle(tr("Хранить подробную историю ресурсов"), isOn: $historyEnabled)
                    .accessibilityLabel(tr("Хранить подробную историю ресурсов"))
                LabeledContent(tr("История ресурсов"), value: tr("7 дней"))
                LabeledContent(tr("Размер базы"), value: MetricFormat.bytes(model.databaseSizeBytes))
                Picker(tr("История разрядов батареи"), selection: $batteryRetentionDays) {
                    Text(tr("Хранить без ограничения")).tag(0)
                    Text(tr("30 дней")).tag(30)
                    Text(tr("90 дней")).tag(90)
                    Text(tr("365 дней")).tag(365)
                }
                Text(tr("Срок применяется к завершённым разрядам. Текущий разряд сохраняется. Удаление старых разрядов может изменить оценку работы от полного заряда."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(tr("Учёт бодрствования и батареи хранится только на этом Mac. Между компьютерами ничего не синхронизируется."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr("Здоровье SSD")) {
                SSDHealthSummary(snapshot: model.ssdHealth)
                if let error = model.ssdHealthError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button(tr("Все накопители…")) {
                        AppServices.shared.ssdHealthController.show(model: model)
                    }
                    if model.ssdHealthLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    Button(tr("Обновить")) { model.refreshSSDHealth() }
                        .disabled(model.ssdHealthLoading)
                }
            }

            Section(tr("Необязательный мост MemPalace")) {
                Text(tr("Команда ставит отметки начала и конца задачи. PurrCore не читает содержимое памяти и не переносит туда сырые метрики."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(integrationCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(tr("Скопировать")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(integrationCommand, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 680)
        .padding(.top, 6)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            batteryRetentionDays = UserDefaults.standard.integer(forKey: AppDefaults.batteryRetentionDays)
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
            applyLaunchAtLogin(isEnabled)
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
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchHint = error.localizedDescription
        }
    }
}

private struct StatusItemPreview: View {
    @ObservedObject var model: AppModel
    let metricRawValue: String
    let animationEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var interval: TimeInterval {
        CatSpeedPolicy.frameInterval(cpuPercent: model.snapshot.cpuPercent)
    }

    private var metricValue: String {
        (StatusMetric(rawValue: metricRawValue) ?? .cpu).menuBarValue(for: model.snapshot)
    }

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 5) {
                Group {
                    if animationEnabled && !reduceMotion {
                        TimelineView(.animation(minimumInterval: interval)) { context in
                            let frame = Int(context.date.timeIntervalSinceReferenceDate / interval)
                                % CatAnimationConfig.frameCount
                            PetFrameImage(frame: frame, animation: model.petAnimation)
                        }
                    } else {
                        PetFrameImage(frame: 0, animation: model.petAnimation)
                    }
                }
                .frame(width: CatAsset.menuBarSize.width, height: CatAsset.menuBarSize.height)

                if !metricValue.isEmpty {
                    Text(metricValue)
                        .font(Font(AppFonts.statusItemButton))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(.regularMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tr("Предпросмотр строки меню"))
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
