import Foundation

/// Languages the interface can be shown in. Vietnamese is the source: every
/// string in the code is written in Vietnamese and doubles as the lookup key.
enum Language: String, CaseIterable, Identifiable {
    case vi
    case en
    case ru

    var id: String { rawValue }

    /// Always shown in its own language, so it can be found from any other.
    var nativeName: String {
        switch self {
        case .vi: return "Tiếng Việt"
        case .en: return "English"
        case .ru: return "Русский"
        }
    }
}

enum L10n {
    static let defaultsKey = "app.language"

    /// Read by `L(_:)` while views render. Set through `MenuBarSettings`.
    static var current: Language =
        Language(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .vi

    static func table(for language: Language) -> [String: String] {
        switch language {
        case .vi: return [:]
        case .en: return Translations.en
        case .ru: return Translations.ru
        }
    }
}

/// The interface string for `key` (its Vietnamese text) in the current
/// language, falling back to the Vietnamese when a translation is missing.
func L(_ key: String) -> String {
    L10n.table(for: L10n.current)[key] ?? key
}

/// `L(_:)` for a `String(format:)` template such as `"còn %@"`.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
