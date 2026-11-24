import Foundation

enum PurrCoreResources {
    private static let bundleName = "PurrCore_PurrCore.bundle"

    /// Safely resolves the SwiftPM resource bundle in both packaged `.app` bundles
    /// (`Contents/Resources/`) and local `swift build` / `swift test` layouts without
    /// calling `Bundle.module`, whose generated accessor traps with `fatalError`.
    static let bundle: Bundle = {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName)
        ]
        for case let url? in candidates {
            if let found = Bundle(url: url) {
                return found
            }
        }
        return Bundle.main
    }()
}

/// Localize display text without changing persisted process groups or history.
private enum Localization {
    static let bundle: Bundle = {
        let language = Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en"
        return PurrCoreResources.bundle.path(forResource: language, ofType: "lproj")
            .flatMap { Bundle(path: $0) } ?? PurrCoreResources.bundle
    }()
}

func tr(_ key: String, _ arguments: CVarArg...) -> String {
    let value = Localization.bundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return value }
    // Display formats use %@ only; a literal percent must survive formatting.
    let format = value.replacingOccurrences(of: "%(?!@)", with: "%%", options: .regularExpression)
    return String(format: format, locale: Locale.current, arguments: arguments)
}
