import Foundation
import Combine
import AppKit

final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    private let defaults = UserDefaults.standard

    // MARK: - General

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "isEnabled") }
    }

    @Published var autoStartOnLogin: Bool {
        didSet {
            defaults.set(autoStartOnLogin, forKey: "autoStartOnLogin")
            updateLaunchAgent()
        }
    }

    @Published var showNotifications: Bool {
        didSet { defaults.set(showNotifications, forKey: "showNotifications") }
    }

    // MARK: - Detection

    enum Sensitivity: Int, CaseIterable, Identifiable {
        case low = 0
        case medium = 1
        case high = 2
        case veryHigh = 3

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .veryHigh: return "Very High"
            }
        }

        /// Confidence a candidate correction must reach before it is applied —
        /// lower = more aggressive switching. Compared against `LanguageDetector.Evidence.score`;
        /// see `LanguageDetector.Weight` for how these numbers line up with the signals.
        var scoreThreshold: Int {
            switch self {
            case .low: return 20
            case .medium: return 10
            case .high: return 5
            case .veryHigh: return 2
            }
        }
    }

    @Published var sensitivity: Sensitivity {
        didSet { defaults.set(sensitivity.rawValue, forKey: "sensitivity") }
    }

    /// Delay in milliseconds between correction steps
    @Published var correctionDelayMs: Int {
        didSet { defaults.set(correctionDelayMs, forKey: "correctionDelayMs") }
    }

    /// Minimum word length to trigger detection
    @Published var minWordLength: Int {
        didSet { defaults.set(minWordLength, forKey: "minWordLength") }
    }

    // MARK: - Per-App Rules

    struct AppRule: Codable, Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        var isExcluded: Bool
    }

    @Published var appRules: [AppRule] {
        didSet { saveAppRules() }
    }

    // MARK: - Custom Dictionaries

    @Published var customEnglishWords: [String] {
        didSet { defaults.set(customEnglishWords, forKey: "customEnglishWords") }
    }

    @Published var customUkrainianWords: [String] {
        didSet { defaults.set(customUkrainianWords, forKey: "customUkrainianWords") }
    }

    // MARK: - Custom Dictionary Files

    @Published var customEnglishDictionaryPaths: [String] {
        didSet {
            defaults.set(customEnglishDictionaryPaths, forKey: "customEnglishDictionaryPaths")
        }
    }

    @Published var customUkrainianDictionaryPaths: [String] {
        didSet {
            defaults.set(customUkrainianDictionaryPaths, forKey: "customUkrainianDictionaryPaths")
        }
    }

    // MARK: - Self-Learning (exception words that should NOT be corrected)

    @Published var exceptionWords: [String] {
        didSet {
            defaults.set(exceptionWords, forKey: "exceptionWords")
            exceptionSet = Set(exceptionWords)
        }
    }

    /// Membership mirror of `exceptionWords`. The list is consulted on every word boundary
    /// and grows without bound through self-learning, so a linear scan is the wrong shape.
    private var exceptionSet: Set<String> = []

    /// Ceiling on the self-learned exception list. Reached only by pathological usage;
    /// without it a user who keeps undoing corrections grows the list forever.
    static let maxExceptionWords = 5000

    // MARK: - Undo Hotkey

    /// Virtual keycode for the undo hotkey. 0 = disabled.
    /// Default 0x06 = 'Z'.
    @Published var undoHotkeyKeyCode: Int {
        didSet { defaults.set(undoHotkeyKeyCode, forKey: "undoHotkeyKeyCode") }
    }

    /// Raw bitmask of NSEvent.ModifierFlags (already &.deviceIndependentFlagsMask).
    /// Default = Control+Shift.
    @Published var undoHotkeyModifiers: UInt {
        didSet { defaults.set(Int(bitPattern: undoHotkeyModifiers), forKey: "undoHotkeyModifiers") }
    }

    var undoHotkeyIsEnabled: Bool { undoHotkeyKeyCode != 0 }

    /// Human-readable hotkey: e.g. "⌃⇧Z"
    var undoHotkeyDescription: String {
        guard undoHotkeyIsEnabled else { return "Disabled" }
        let flags = NSEvent.ModifierFlags(rawValue: undoHotkeyModifiers)
        var s = ""
        if flags.contains(.control) { s += "\u{2303}" }   // ⌃
        if flags.contains(.option)  { s += "\u{2325}" }   // ⌥
        if flags.contains(.shift)   { s += "\u{21E7}" }   // ⇧
        if flags.contains(.command) { s += "\u{2318}" }   // ⌘
        s += Self.keyCodeLabel(UInt16(undoHotkeyKeyCode))
        return s
    }

    /// Best-effort human label for a virtual keycode.
    static func keyCodeLabel(_ kc: UInt16) -> String {
        switch kc {
        case 0x00: return "A"
        case 0x01: return "S"
        case 0x02: return "D"
        case 0x03: return "F"
        case 0x04: return "H"
        case 0x05: return "G"
        case 0x06: return "Z"
        case 0x07: return "X"
        case 0x08: return "C"
        case 0x09: return "V"
        case 0x0B: return "B"
        case 0x0C: return "Q"
        case 0x0D: return "W"
        case 0x0E: return "E"
        case 0x0F: return "R"
        case 0x10: return "Y"
        case 0x11: return "T"
        case 0x1F: return "O"
        case 0x20: return "U"
        case 0x22: return "I"
        case 0x23: return "P"
        case 0x25: return "L"
        case 0x26: return "J"
        case 0x28: return "K"
        case 0x2D: return "N"
        case 0x2E: return "M"
        case 0x12: return "1"
        case 0x13: return "2"
        case 0x14: return "3"
        case 0x15: return "4"
        case 0x16: return "6"
        case 0x17: return "5"
        case 0x19: return "9"
        case 0x1A: return "7"
        case 0x1C: return "8"
        case 0x1D: return "0"
        case 0x24: return "\u{21A9}"   // return
        case 0x30: return "\u{21E5}"   // tab
        case 0x31: return "Space"
        case 0x33: return "\u{232B}"   // backspace
        case 0x35: return "Esc"
        case 0x7B: return "\u{2190}"   // left
        case 0x7C: return "\u{2192}"   // right
        case 0x7D: return "\u{2193}"   // down
        case 0x7E: return "\u{2191}"   // up
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        default:   return "Key\(kc)"
        }
    }

    // MARK: - Statistics

    @Published var totalCorrections: Int {
        didSet { defaults.set(totalCorrections, forKey: "totalCorrections") }
    }

    @Published var sessionCorrections: Int = 0

    // MARK: - Init

    private init() {
        self.isEnabled = defaults.object(forKey: "isEnabled") as? Bool ?? true
        self.autoStartOnLogin = defaults.object(forKey: "autoStartOnLogin") as? Bool ?? false
        self.showNotifications = defaults.object(forKey: "showNotifications") as? Bool ?? true

        let rawSensitivity = defaults.object(forKey: "sensitivity") as? Int ?? Sensitivity.medium.rawValue
        self.sensitivity = Sensitivity(rawValue: rawSensitivity) ?? .medium

        self.correctionDelayMs = defaults.object(forKey: "correctionDelayMs") as? Int ?? 50
        self.minWordLength = defaults.object(forKey: "minWordLength") as? Int ?? 2

        self.customEnglishWords = defaults.object(forKey: "customEnglishWords") as? [String] ?? []
        self.customUkrainianWords = defaults.object(forKey: "customUkrainianWords") as? [String] ?? []

        let storedExceptions = defaults.object(forKey: "exceptionWords") as? [String] ?? []
        self.exceptionWords = storedExceptions
        // didSet does not fire during init, so seed the membership mirror by hand.
        self.exceptionSet = Set(storedExceptions)

        self.customEnglishDictionaryPaths = defaults.object(forKey: "customEnglishDictionaryPaths") as? [String] ?? []
        self.customUkrainianDictionaryPaths = defaults.object(forKey: "customUkrainianDictionaryPaths") as? [String] ?? []

        self.totalCorrections = defaults.object(forKey: "totalCorrections") as? Int ?? 0

        self.undoHotkeyKeyCode = defaults.object(forKey: "undoHotkeyKeyCode") as? Int ?? 0x06 // 'Z'
        let defaultMods = NSEvent.ModifierFlags([.control, .shift]).rawValue
        if let stored = defaults.object(forKey: "undoHotkeyModifiers") as? Int {
            self.undoHotkeyModifiers = UInt(bitPattern: stored)
        } else {
            self.undoHotkeyModifiers = defaultMods
        }

        if let data = defaults.data(forKey: "appRules"),
           let rules = try? JSONDecoder().decode([AppRule].self, from: data) {
            self.appRules = rules
        } else {
            self.appRules = []
        }
    }

    // MARK: - Helpers

    func recordCorrection() {
        totalCorrections += 1
        sessionCorrections += 1
    }

    func resetStatistics() {
        totalCorrections = 0
        sessionCorrections = 0
    }

    func addException(_ word: String) {
        let lower = word.lowercased()
        guard !lower.isEmpty, !exceptionSet.contains(lower) else { return }
        if exceptionWords.count >= Self.maxExceptionWords {
            exceptionWords.removeFirst()
        }
        exceptionWords.append(lower)
        debugLog("[LayoutSwitcher] Self-learning: added '\(lower)' to exceptions")
    }

    func isException(_ word: String) -> Bool {
        exceptionSet.contains(word.lowercased())
    }

    func isAppExcluded(bundleID: String) -> Bool {
        appRules.first(where: { $0.bundleID == bundleID && $0.isExcluded }) != nil
    }

    private func saveAppRules() {
        if let data = try? JSONEncoder().encode(appRules) {
            defaults.set(data, forKey: "appRules")
        }
    }

    private func updateLaunchAgent() {
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.layoutswitcher.plist"
        let fm = FileManager.default

        if autoStartOnLogin {
            let execPath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
            let plist: [String: Any] = [
                "Label": "com.layoutswitcher",
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]

            let dir = NSHomeDirectory() + "/Library/LaunchAgents"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

            let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            fm.createFile(atPath: plistPath, contents: data)
        } else {
            try? fm.removeItem(atPath: plistPath)
        }
    }
}
