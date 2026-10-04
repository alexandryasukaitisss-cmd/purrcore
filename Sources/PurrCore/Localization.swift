import Foundation

/// Localize display text without changing persisted process groups or history.
private enum Localization {
    static let bundle: Bundle = {
        let language = Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en"
        return Bundle.module.path(forResource: language, ofType: "lproj")
            .flatMap { Bundle(path: $0) } ?? Bundle.module
    }()
}

func tr(_ key: String, _ arguments: CVarArg...) -> String {
    let value = Localization.bundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return value }
    // Display formats use %@ only; a literal percent must survive formatting.
    let format = value.replacingOccurrences(of: "%(?!@)", with: "%%", options: .regularExpression)
    return String(format: format, locale: Locale.current, arguments: arguments)
}
