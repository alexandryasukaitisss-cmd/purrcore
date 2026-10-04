import Foundation

public struct ProcessHumanizer: Sendable {
    private struct KnownProcess {
        let displayName: String
        let groupKey: String
        let explanation: String
    }

    private static let knownProcesses: [String: KnownProcess] = [
        "windowserver": .init(displayName: "Окна и графика macOS", groupKey: "system:window-server", explanation: "отрисовка окон и экранов"),
        "kernel_task": .init(displayName: "Ядро macOS", groupKey: "system:kernel", explanation: "драйверы, питание и температура"),
        "mds": .init(displayName: "Индексация Spotlight", groupKey: "system:spotlight", explanation: "поиск и индексирование файлов"),
        "mds_stores": .init(displayName: "Индексация Spotlight", groupKey: "system:spotlight", explanation: "поиск и индексирование файлов"),
        "mdworker": .init(displayName: "Индексация Spotlight", groupKey: "system:spotlight", explanation: "поиск и индексирование файлов"),
        "mdworker_shared": .init(displayName: "Индексация Spotlight", groupKey: "system:spotlight", explanation: "поиск и индексирование файлов"),
        "cloudd": .init(displayName: "Синхронизация iCloud", groupKey: "system:icloud", explanation: "обмен файлами и данными iCloud"),
        "bird": .init(displayName: "Синхронизация iCloud Drive", groupKey: "system:icloud", explanation: "файлы iCloud Drive"),
        "backupd": .init(displayName: "Резервная копия Time Machine", groupKey: "system:time-machine", explanation: "создание резервной копии"),
        "photolibraryd": .init(displayName: "Медиатека Фото", groupKey: "system:photos", explanation: "анализ и синхронизация фотографий"),
        "corespotlightd": .init(displayName: "Индексация Spotlight", groupKey: "system:spotlight", explanation: "поиск и индексирование файлов"),
        "trustd": .init(displayName: "Проверка безопасности macOS", groupKey: "system:security", explanation: "сертификаты и доверие приложений")
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
                category: .system
            )
        }

        let helperExplanation = explanation(for: rawName)
        if let appName = outerApplicationName(in: path) {
            return ProcessDescriptor(
                groupKey: "app:\(slug(appName))",
                displayName: appName,
                explanation: helperExplanation,
                category: category(for: appName)
            )
        }

        let normalizedName = normalizedProcessName(rawName)
        return ProcessDescriptor(
            groupKey: "process:\(slug(normalizedName))",
            displayName: normalizedName,
            explanation: helperExplanation,
            category: category(for: normalizedName)
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

    private func explanation(for rawName: String) -> String {
        let lower = rawName.lowercased()
        if lower.contains("renderer") || lower.contains("webcontent") {
            return "вкладки и веб‑контент"
        }
        if lower.contains("gpu") {
            return "графика и видео"
        }
        if lower.contains("helper") {
            return "служебные процессы приложения"
        }
        return "основной процесс"
    }

    private func category(for name: String) -> ProcessCategory {
        let value = name.lowercased()
        if containsAny(value, ["safari", "chrome", "brave", "firefox", "arc", "opera", "edge", "orion"]) {
            return .browser
        }
        if containsAny(value, ["codex", "chatgpt", "claude", "ollama", "mempalace", "lm studio", "cursor"]) {
            return .ai
        }
        if containsAny(value, ["xcode", "terminal", "iterm", "visual studio", "vscode", "zed", "docker", "git", "swift", "python", "node"]) {
            return .development
        }
        if containsAny(value, ["telegram", "messages", "slack", "discord", "zoom", "teams", "mail", "whatsapp"]) {
            return .communication
        }
        if containsAny(value, ["music", "spotify", "vlc", "quicktime", "photos", "photo", "tv"]) {
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
