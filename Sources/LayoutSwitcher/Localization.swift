import Foundation
import Combine

/// The interface language, as chosen in Settings.
enum AppLanguage: String, CaseIterable, Identifiable {
    /// Follow the languages configured in System Settings.
    case system
    case english = "en"
    case ukrainian = "uk"

    var id: String { rawValue }

    /// Every language is named in itself — the convention macOS uses in its own language
    /// list, and the only labelling that stays readable to someone who picked the wrong
    /// one and needs to find their way back.
    var displayName: String {
        switch self {
        case .system: return L("language.system")
        case .english: return "English"
        case .ukrainian: return "\u{0423}\u{043A}\u{0440}\u{0430}\u{0457}\u{043D}\u{0441}\u{044C}\u{043A}\u{0430}"
        }
    }

    /// The `.lproj` this maps to, resolving `.system` against the user's language order.
    var localizationCode: String {
        switch self {
        case .english: return "en"
        case .ukrainian: return "uk"
        case .system:
            let available = AppLanguage.allCases.compactMap { $0 == .system ? nil : $0.rawValue }
            return Bundle.preferredLocalizations(from: available).first ?? "en"
        }
    }
}

/// Looks strings up in the bundled `.strings` tables and re-publishes when the language
/// changes, so the UI re-renders in place.
///
/// The alternative — rewriting `AppleLanguages` in user defaults — only takes effect after
/// a relaunch, which for a menu-bar app means telling the user to quit and reopen something
/// they never deliberately opened. Selecting the `.lproj` ourselves costs one lookup table
/// and switches instantly.
final class Localization: ObservableObject {
    static let shared = Localization()

    private static let defaultsKey = "appLanguage"
    private let defaults = UserDefaults.standard

    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language.rawValue, forKey: Self.defaultsKey)
            table = Self.loadTable(for: language)
        }
    }

    /// Key → translated string for the active language.
    private var table: [String: String]

    /// English, always loaded, as the fallback for any key a translation has not caught up
    /// with yet. A missing translation should read as untranslated English, never as a raw
    /// dotted key.
    private let englishTable: [String: String]

    private init() {
        let stored = defaults.string(forKey: Self.defaultsKey)
        let initial = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.language = initial
        self.englishTable = Self.loadTable(forCode: "en")
        self.table = Self.loadTable(for: initial)

        if englishTable.isEmpty {
            print("[MacKeySwitch] WARNING: no localization tables found — "
                  + "the UI will fall back to built-in English.")
        }
    }

    /// The translation for `key`, or the English one, or the key itself.
    func string(_ key: String) -> String {
        table[key] ?? englishTable[key] ?? key
    }

    /// Where the tables were found and how many strings each holds. Printed by
    /// `--print-diagnostics`: "why is my interface still in English?" is otherwise an
    /// invisible failure, since a missing table degrades silently to the English fallback.
    func diagnosticsReport() -> String {
        var lines = ["Interface language: \(language.rawValue) -> \(language.localizationCode)"]
        lines.append("Bundle.main: \(Bundle.main.bundleURL.path)")
        lines.append("Resource bundle: \(ResourceBundle.main?.bundlePath ?? "NOT FOUND")")
        for code in ["en", "uk"] {
            let count = Self.loadTable(forCode: code).count
            let source = [Bundle.main, ResourceBundle.main]
                .compactMap { $0?.path(forResource: code, ofType: "lproj") }
                .first ?? "NOT FOUND"
            lines.append("\(code).lproj: \(count) strings — \(source)")
        }
        lines.append("Sample (\"menu.quit\"): \(string("menu.quit"))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Loading

    private static func loadTable(for language: AppLanguage) -> [String: String] {
        loadTable(forCode: language.localizationCode)
    }

    /// Read one `Localizable.strings` file.
    ///
    /// Parsed as a property list rather than through `Bundle.localizedString`, because that
    /// API resolves the language itself from the process's preferences — the very thing
    /// this type exists to override. (`.strings` files are old-style property lists, which
    /// `PropertyListSerialization` reads natively.)
    private static func loadTable(forCode code: String) -> [String: String] {
        // `Bundle.main` first: in a shipped .app the tables sit at the standard
        // Contents/Resources/<code>.lproj. The SwiftPM resource bundle is the fallback, for
        // `swift run` builds where there is no .app around the executable.
        let candidates = [Bundle.main, ResourceBundle.main].compactMap { $0 }
        for bundle in candidates {
            guard let lprojPath = bundle.path(forResource: code, ofType: "lproj") else {
                continue
            }
            let url = URL(fileURLWithPath: lprojPath)
                .appendingPathComponent("Localizable.strings")
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ) as? [String: String]
            else {
                continue
            }
            return plist
        }
        return [:]
    }
}

/// Shorthand for a localized string. Deliberately terse — it wraps most user-facing text
/// in the app, and a longer name would drown the strings themselves.
func L(_ key: String) -> String {
    Localization.shared.string(key)
}

/// Localized format string, applied to `args`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localization.shared.string(key), arguments: args)
}
