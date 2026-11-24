import Foundation

public struct ProcessHumanizer: Sendable {
    private struct KnownProcess {
        let displayName: String
        let groupKey: String
        let explanation: String
        let category: ProcessCategory

        init(displayName: String, groupKey: String, explanation: String, category: ProcessCategory = .system) {
            self.displayName = displayName
            self.groupKey = groupKey
            self.explanation = explanation
            self.category = category
        }
    }

    private static let knownProcesses: [String: KnownProcess] = [
        // Graphics, Windowing & Desktop
        "windowserver": .init(displayName: "Окна и графика macOS", groupKey: "system:window-server", explanation: "отрисовка окон и экранов"),
        "dock": .init(displayName: "Dock и рабочие столы", groupKey: "system:dock", explanation: "панель Dock, Spaces и переключение окон"),
        "finder": .init(displayName: "Finder", groupKey: "system:finder", explanation: "файлы, рабочий стол и внешние диски"),
        "controlcenter": .init(displayName: "Пункт управления macOS", groupKey: "system:control-center", explanation: "меню-бар, звук, сеть и экран"),
        "notificationcenter": .init(displayName: "Центр уведомлений", groupKey: "system:notifications", explanation: "уведомления и виджеты macOS"),
        "systemuiserver": .init(displayName: "Строка меню macOS", groupKey: "system:menu-bar", explanation: "системные значки строки меню"),
        "loginwindow": .init(displayName: "Сеанс входа macOS", groupKey: "system:login", explanation: "управление экраном входа и блокировкой"),
        "corebrightnessd": .init(displayName: "Яркость и True Tone", groupKey: "system:brightness", explanation: "управление яркостью и Night Shift"),
        "chronod": .init(displayName: "Виджеты macOS", groupKey: "system:widgets", explanation: "обновление виджетов рабочего стола"),

        // Kernel, Power & Storage
        "kernel_task": .init(displayName: "Ядро macOS", groupKey: "system:kernel", explanation: "драйверы, питание и температура"),
        "launchd": .init(displayName: "Диспетчер служб launchd", groupKey: "system:launchd", explanation: "запуск приложений и фоновых агентов"),
        "powerd": .init(displayName: "Управление питанием", groupKey: "system:power", explanation: "режим сна, пробуждение и батарея"),
        "thermald": .init(displayName: "Термоконтроль macOS", groupKey: "system:thermal", explanation: "контроль нагрева и охлаждения"),
        "hidd": .init(displayName: "Устройства ввода", groupKey: "system:hid", explanation: "клавиатура, мышь и трекпад"),
        "fseventsd": .init(displayName: "Монитор файлов macOS", groupKey: "system:fsevents", explanation: "отслеживание изменений в файловой системе"),
        "diskarbitrationd": .init(displayName: "Подключение дисков", groupKey: "system:disk-arbitration", explanation: "монтирование и извлечение накопителей"),
        "apfsd": .init(displayName: "Файловая система APFS", groupKey: "system:apfs", explanation: "работа томов и снимков APFS"),
        "fsck_apfs": .init(displayName: "Проверка диска APFS", groupKey: "system:apfs-check", explanation: "проверка целостности файловой системы"),

        // Spotlight & Search
        "mds": .init(displayName: "Индексация Spotlight", groupKey: "system:spotlight", explanation: "поиск и индексирование файлов"),
        "mds_stores": .init(displayName: "Индексация Spotlight", groupKey: "system:spotlight", explanation: "поиск и индексирование файлов"),
        "mdworker": .init(displayName: "Индексация Spotlight", groupKey: "system:spotlight", explanation: "поиск и индексирование файлов"),
        "mdworker_shared": .init(displayName: "Индексация Spotlight", groupKey: "system:spotlight", explanation: "поиск и индексирование файлов"),
        "corespotlightd": .init(displayName: "Индексация Spotlight", groupKey: "system:spotlight", explanation: "поиск и индексирование файлов"),
        "spotlight": .init(displayName: "Поиск Spotlight", groupKey: "system:spotlight", explanation: "поиск и индексирование файлов"),

        // iCloud, Sync & Backups
        "cloudd": .init(displayName: "Синхронизация iCloud", groupKey: "system:icloud", explanation: "обмен файлами и данными iCloud"),
        "bird": .init(displayName: "Синхронизация iCloud Drive", groupKey: "system:icloud", explanation: "файлы iCloud Drive"),
        "fileproviderd": .init(displayName: "Облачные диски", groupKey: "system:file-provider", explanation: "синхронизация iCloud Drive и облачных папок"),
        "nsurlsessiond": .init(displayName: "Фоновые загрузки macOS", groupKey: "system:background-downloads", explanation: "фоновая передача файлов и обновлений"),
        "backupd": .init(displayName: "Резервная копия Time Machine", groupKey: "system:time-machine", explanation: "создание резервной копии"),
        "tmutil": .init(displayName: "Резервная копия Time Machine", groupKey: "system:time-machine", explanation: "управление копиями Time Machine"),

        // Photos & Media Analysis
        "photolibraryd": .init(displayName: "Медиатека Фото", groupKey: "system:photos", explanation: "анализ и синхронизация фотографий", category: .media),
        "photoanalysisd": .init(displayName: "Анализ фотографий", groupKey: "system:photos", explanation: "распознавание лиц, объектов и воспоминаний", category: .media),
        "mediaanalysisd": .init(displayName: "Анализ медиафайлов", groupKey: "system:media-analysis", explanation: "индексация фото, видео и Live Text", category: .media),
        "vtdecoderxpcservice": .init(displayName: "Аппаратное декодирование видео", groupKey: "system:video-codec", explanation: "воспроизведение и декодирование видео", category: .media),
        "vtencoderxpcservice": .init(displayName: "Аппаратное кодирование видео", groupKey: "system:video-codec", explanation: "запись и сжатие видео", category: .media),
        "coreaudiod": .init(displayName: "Аудиосистема macOS", groupKey: "system:audio", explanation: "вывод звука и работа микрофонов", category: .media),
        "audiomxd": .init(displayName: "Микшер аудио macOS", groupKey: "system:audio", explanation: "маршрутизация аудиопотоков", category: .media),
        "cgpdfservice": .init(displayName: "Отрисовка PDF macOS", groupKey: "system:pdf", explanation: "предпросмотр и рендеринг PDF‑документов"),

        // WebKit / Safari XPC Services
        "com.apple.webkit.webcontent": .init(displayName: "Веб‑страницы WebKit", groupKey: "browser:webkit", explanation: "вкладки Safari и встроенных веб‑окон", category: .browser),
        "com.apple.webkit.gpu": .init(displayName: "Графика WebKit", groupKey: "browser:webkit", explanation: "видео и графика веб‑страниц Safari", category: .browser),
        "com.apple.webkit.networking": .init(displayName: "Сеть WebKit", groupKey: "browser:webkit", explanation: "сетевые запросы вкладок Safari", category: .browser),

        // Security, Updates & Networking
        "trustd": .init(displayName: "Проверка безопасности macOS", groupKey: "system:security", explanation: "сертификаты и доверие приложений"),
        "syspolicyd": .init(displayName: "Защита Gatekeeper", groupKey: "system:security", explanation: "проверка подписей и нотарификации программ"),
        "endpointsecurityd": .init(displayName: "Служба безопасности macOS", groupKey: "system:security", explanation: "контроль доступа и событий безопасности"),
        "eslogger": .init(displayName: "Журнал безопасности macOS", groupKey: "system:security", explanation: "мониторинг системных событий безопасности"),
        "softwareupdated": .init(displayName: "Обновление macOS", groupKey: "system:updates", explanation: "проверка и загрузка системных обновлений"),
        "mobileassetd": .init(displayName: "Ресурсы macOS", groupKey: "system:updates", explanation: "загрузка шрифтов, голосов и словарей"),
        "bluetoothd": .init(displayName: "Bluetooth macOS", groupKey: "system:bluetooth", explanation: "связь с наушниками, клавиатурой и мышью"),
        "airportd": .init(displayName: "Wi‑Fi macOS", groupKey: "system:wifi", explanation: "управление беспроводным подключением"),
        "wifid": .init(displayName: "Wi‑Fi macOS", groupKey: "system:wifi", explanation: "управление беспроводным подключением"),
        "rapportd": .init(displayName: "Continuity и AirDrop", groupKey: "system:continuity", explanation: "связь между Mac, iPhone и iPad"),
        "sharingd": .init(displayName: "AirDrop и Handoff", groupKey: "system:continuity", explanation: "общий буфер, AirDrop и Handoff"),
        "airplayxpchelper": .init(displayName: "AirPlay и Sidecar", groupKey: "system:airplay", explanation: "трансляция экрана на iPad и ТВ"),

        // Logging, Intelligence & Background Maintenance
        "logd": .init(displayName: "Системные журналы macOS", groupKey: "system:logging", explanation: "сбор диагностических логов системы"),
        "syslogd": .init(displayName: "Системные журналы macOS", groupKey: "system:logging", explanation: "запись системных журналов"),
        "cfprefsd": .init(displayName: "Настройки приложений macOS", groupKey: "system:prefs", explanation: "чтение и сохранение параметров программ"),
        "distnoted": .init(displayName: "События приложений macOS", groupKey: "system:events", explanation: "передача системных уведомлений между программами"),
        "usereventagent": .init(displayName: "Фоновые события macOS", groupKey: "system:events", explanation: "реакция на системные триггеры и устройства"),
        "duetexpertd": .init(displayName: "Подсказки и прогноз macOS", groupKey: "system:intelligence", explanation: "фоновый анализ привычек и рекомендаций Siri"),
        "suggestd": .init(displayName: "Подсказки Siri", groupKey: "system:intelligence", explanation: "поиск событий, контактов и подсказок"),
        "knowledge-agent": .init(displayName: "База активности macOS", groupKey: "system:intelligence", explanation: "локальный учёт контекста для Siri и Экранного времени"),
        "biomesyncd": .init(displayName: "Синхронизация Siri и Focus", groupKey: "system:intelligence", explanation: "синхронизация режимов фокусирования и подсказок"),
        "triald": .init(displayName: "Эксперименты и модели macOS", groupKey: "system:intelligence", explanation: "обновление системных ML‑моделей и параметров"),
        "backgroundshortcutrunner": .init(displayName: "Быстрые команды", groupKey: "system:shortcuts", explanation: "фоновое выполнение автоматизаций Shortcuts"),

        // Compilers, Graphics Shaders & Runtimes
        "mtlcompilerservice": .init(displayName: "Компиляция шейдеров Metal", groupKey: "dev:metal", explanation: "подготовка графических шейдеров GPU", category: .development),
        "swift-frontend": .init(displayName: "Компилятор Swift", groupKey: "dev:swift", explanation: "сборка Swift‑кода", category: .development),
        "sourcekit-lsp": .init(displayName: "Анализ кода Swift", groupKey: "dev:swift", explanation: "подсветка, автодополнение и индексация кода", category: .development),
        "clang": .init(displayName: "Компилятор C/C++", groupKey: "dev:clang", explanation: "компиляция нативного кода", category: .development),
        "node": .init(displayName: "Node.js", groupKey: "process:node", explanation: "серверы, инструменты сборки и агенты JS", category: .development),
        "python3": .init(displayName: "Python", groupKey: "process:python", explanation: "скрипты, сервисы и обработка данных", category: .development),
        "python": .init(displayName: "Python", groupKey: "process:python", explanation: "скрипты, сервисы и обработка данных", category: .development),
        "ollama": .init(displayName: "Ollama", groupKey: "ai:ollama", explanation: "локальные языковые модели", category: .ai),
    ]

    public init() {}

    public func describe(executableName: String, path: String) -> ProcessDescriptor {
        let rawName = executableName.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : executableName
        let lowerName = rawName.lowercased()

        if let known = Self.knownProcesses[lowerName] {
            return ProcessDescriptor(
                groupKey: known.groupKey,
                displayName: known.displayName,
                explanation: known.explanation,
                category: known.category,
                explanationPriority: 100
            )
        }
        if lowerName.hasPrefix("python3."), let known = Self.knownProcesses["python3"] {
            return ProcessDescriptor(
                groupKey: known.groupKey,
                displayName: known.displayName,
                explanation: known.explanation,
                category: known.category,
                explanationPriority: 100
            )
        }

        let (helperExplanation, priority) = explanationAndPriority(for: rawName)
        if let appName = outerApplicationName(in: path) {
            return ProcessDescriptor(
                groupKey: "app:\(slug(appName))",
                displayName: appName,
                explanation: helperExplanation,
                category: category(for: appName),
                explanationPriority: priority
            )
        }

        let normalizedName = normalizedProcessName(rawName)
        return ProcessDescriptor(
            groupKey: "process:\(slug(normalizedName))",
            displayName: normalizedName,
            explanation: helperExplanation,
            category: category(for: normalizedName),
            explanationPriority: priority
        )
    }

    private func outerApplicationName(in path: String) -> String? {
        guard !path.isEmpty else { return nil }

        let lowerPath = path.lowercased()
        guard let marker = lowerPath.range(of: ".app/") else {
            if lowerPath.hasSuffix(".app") {
                return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            }
            return nil
        }

        let appPath = String(path[..<marker.upperBound]).dropLast()
        let url = URL(fileURLWithPath: String(appPath))
        let bundle = Bundle(url: url)
        let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        return bundleName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func normalizedProcessName(_ rawName: String) -> String {
        let suffixes = [
            " Helper (Renderer)",
            " Helper (GPU)",
            " Helper (Plugin)",
            " Helper",
            " (Renderer)",
            " Renderer"
        ]

        var result = rawName
        for suffix in suffixes where result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
            break
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Неизвестный процесс"
    }

    private func explanationAndPriority(for rawName: String) -> (String, Int) {
        let lower = rawName.lowercased()
        if lower.contains("renderer") || lower.contains("webcontent") {
            return ("вкладки и веб‑контент", 30)
        }
        if lower.contains("gpu") {
            return ("графика и видео", 20)
        }
        if lower.contains("helper") || lower.contains("plugin") || lower.contains("utility") {
            return ("служебные процессы приложения", 10)
        }
        return ("основной процесс", 50)
    }

    private func category(for name: String) -> ProcessCategory {
        let value = name.lowercased()
        if containsAny(value, ["safari", "chrome", "chromium", "brave", "firefox", "arc", "opera", "edge", "orion", "webkit", "dia", "comet"]) {
            return .browser
        }
        if containsAny(value, ["codex", "chatgpt", "claude", "ollama", "mempalace", "lm studio", "cursor", "gemini", "antigravity", "opencode", "openclaw", "hermes", "whisper", "llama", "mlx"]) {
            return .ai
        }
        if containsAny(value, ["xcode", "terminal", "iterm", "ghostty", "warp", "visual studio", "vscode", "zed", "docker", "orbstack", "git", "swift", "python", "node", "bun", "deno", "rust", "cargo", "clang", "postgres", "sqlite", "vite", "esbuild"]) {
            return .development
        }
        if containsAny(value, ["telegram", "messages", "slack", "discord", "zoom", "teams", "mail", "whatsapp", "signal"]) {
            return .communication
        }
        if containsAny(value, ["music", "spotify", "vlc", "quicktime", "photos", "photo", "tv", "iina", "obs", "figma"]) {
            return .media
        }
        if value.hasPrefix("com.apple.") || containsAny(value, ["macos", "system", "finder", "spotlight", "icloud", "time machine"]) {
            return .system
        }
        return .other
    }

    private func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    private func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
