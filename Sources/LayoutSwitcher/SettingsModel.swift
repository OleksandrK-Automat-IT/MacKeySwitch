import Foundation
import Combine
import AppKit
import ServiceManagement

/// A global shortcut: a virtual keycode plus the modifiers held with it.
///
/// Keycode and modifiers travel together as one value on purpose. They used to be two
/// separate `@Published` properties, and the observer that re-registered the Carbon hotkey
/// read them back off the model — but `@Published` emits *before* the property is updated,
/// so the observer always saw the previous value. Recording ⌥⌘K registered ⌃⇧K, and
/// clearing the shortcut re-registered the old one instead of unregistering it.
struct HotkeyBinding: Equatable {
    var keyCode: Int
    /// Raw bitmask of NSEvent.ModifierFlags (already & .deviceIndependentFlagsMask).
    var modifiers: UInt

    static let disabled = HotkeyBinding(keyCode: -1, modifiers: 0)

    /// -1 marks "no shortcut". Keycode 0 used to double as the marker, but 0 is the
    /// letter 'A' — recording ⌃⌥A stored keyCode 0 and the binding silently read back
    /// as disabled. Stored legacy zeros are migrated to -1 on load.
    var isEnabled: Bool { keyCode >= 0 }

    /// Human-readable hotkey: e.g. "⌃⇧Z"
    var description: String {
        guard isEnabled else { return L("hotkey.disabled") }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if flags.contains(.control) { s += "\u{2303}" }   // ⌃
        if flags.contains(.option)  { s += "\u{2325}" }   // ⌥
        if flags.contains(.shift)   { s += "\u{21E7}" }   // ⇧
        if flags.contains(.command) { s += "\u{2318}" }   // ⌘
        s += Self.keyCodeLabel(UInt16(keyCode))
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
}

final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    private let defaults = UserDefaults.standard

    // MARK: - General

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "isEnabled") }
    }

    /// Not persisted in our own defaults — `SMAppService` already stores this, and keeping
    /// a second copy only creates a way for the two to disagree.
    @Published var autoStartOnLogin: Bool {
        didSet { updateLaunchAgent() }
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
            case .low: return L("sensitivity.low")
            case .medium: return L("sensitivity.medium")
            case .high: return L("sensitivity.high")
            case .veryHigh: return L("sensitivity.veryHigh")
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

    /// Pause between erasing the word and retyping it, in milliseconds. Not needed for
    /// ordering — synthetic events are delivered in the order posted — but an escape hatch
    /// for apps that fall behind on rapid input. The slider's floor is 10; the code used to
    /// clamp to 50 underneath it, so the bottom of the slider silently did nothing.
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

    /// The global undo shortcut. Default ⌃⇧Z.
    @Published var undoHotkey: HotkeyBinding {
        didSet {
            defaults.set(undoHotkey.keyCode, forKey: "undoHotkeyKeyCode")
            defaults.set(Int(bitPattern: undoHotkey.modifiers), forKey: "undoHotkeyModifiers")
        }
    }

    /// The shortcuts a fresh install starts with.
    ///
    /// Named rather than inlined so a test can assert they are distinct: Carbon refuses a
    /// duplicate key-and-modifier combination, and the loser of a clash simply never fires.
    enum DefaultHotkeys {
        private static let controlShift = NSEvent.ModifierFlags([.control, .shift]).rawValue

        /// ⌃⇧Z
        static let undo = HotkeyBinding(keyCode: 0x06, modifiers: controlShift)
        /// ⌃⇧Space
        static let correctWord = HotkeyBinding(keyCode: 0x31, modifiers: controlShift)
        /// ⌃⇧X
        static let selection = HotkeyBinding(keyCode: 0x07, modifiers: controlShift)

        static let all: [HotkeyBinding] = [undo, correctWord, selection]
    }

    /// Whether finishing a word may correct it on its own.
    enum CorrectionMode: Int, CaseIterable, Identifiable {
        /// Correct at the word boundary, as soon as the evidence is good enough.
        case automatic = 0
        /// Never correct unaided; wait to be asked. For people who would rather miss a
        /// correction than have one arrive unrequested.
        case hotkeyOnly = 1

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .automatic: return L("mode.automatic")
            case .hotkeyOnly: return L("mode.hotkeyOnly")
            }
        }
    }

    @Published var correctionMode: CorrectionMode {
        didSet { defaults.set(correctionMode.rawValue, forKey: "correctionMode") }
    }

    /// The global shortcut that corrects the last word on demand. Default ⌃⇧Space.
    ///
    /// Available in both modes on purpose. In hotkey-only mode it is the only way to
    /// correct; in automatic mode it is the fallback for the word the detector was not
    /// confident enough about — which is most of the value, since the alternative is
    /// retyping the word by hand.
    @Published var correctWordHotkey: HotkeyBinding {
        didSet {
            defaults.set(correctWordHotkey.keyCode, forKey: "correctWordHotkeyKeyCode")
            defaults.set(Int(bitPattern: correctWordHotkey.modifiers), forKey: "correctWordHotkeyModifiers")
        }
    }

    /// The global shortcut that converts the current selection. Default ⌃⇧X.
    ///
    /// Distinct from the undo shortcut on purpose: undo reverses what the app just did,
    /// this acts on text the app never saw.
    @Published var selectionHotkey: HotkeyBinding {
        didSet {
            defaults.set(selectionHotkey.keyCode, forKey: "selectionHotkeyKeyCode")
            defaults.set(Int(bitPattern: selectionHotkey.modifiers), forKey: "selectionHotkeyModifiers")
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
        // The system is the source of truth here, not our own defaults: the user can turn
        // the login item off in System Settings without ever opening this app.
        self.autoStartOnLogin = LoginItem.isEnabled
        self.showNotifications = defaults.object(forKey: "showNotifications") as? Bool ?? true

        let rawSensitivity = defaults.object(forKey: "sensitivity") as? Int ?? Sensitivity.medium.rawValue
        self.sensitivity = Sensitivity(rawValue: rawSensitivity) ?? .medium

        self.correctionDelayMs = defaults.object(forKey: "correctionDelayMs") as? Int ?? 10
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

        let storedKeyCode = defaults.object(forKey: "undoHotkeyKeyCode") as? Int ?? DefaultHotkeys.undo.keyCode
        // Migrate the legacy "disabled" marker: 0 used to mean "no shortcut" (see
        // HotkeyBinding.isEnabled), so a stored 0 is a cleared binding, never the 'A' key.
        let keyCode = storedKeyCode == 0 ? -1 : storedKeyCode
        let storedMods = defaults.object(forKey: "undoHotkeyModifiers") as? Int
        let modifiers = storedMods.map { UInt(bitPattern: $0) }
            ?? DefaultHotkeys.undo.modifiers
        self.undoHotkey = HotkeyBinding(keyCode: keyCode, modifiers: modifiers)

        let storedSelectionKeyCode = defaults.object(forKey: "selectionHotkeyKeyCode") as? Int ?? DefaultHotkeys.selection.keyCode
        let selectionKeyCode = storedSelectionKeyCode == 0 ? -1 : storedSelectionKeyCode
        let storedSelectionMods = defaults.object(forKey: "selectionHotkeyModifiers") as? Int
        let selectionModifiers = storedSelectionMods.map { UInt(bitPattern: $0) }
            ?? DefaultHotkeys.selection.modifiers
        self.selectionHotkey = HotkeyBinding(keyCode: selectionKeyCode, modifiers: selectionModifiers)

        self.correctionMode = CorrectionMode(
            rawValue: defaults.object(forKey: "correctionMode") as? Int ?? 0
        ) ?? .automatic

        let storedWordKeyCode = defaults.object(forKey: "correctWordHotkeyKeyCode") as? Int ?? DefaultHotkeys.correctWord.keyCode
        let wordKeyCode = storedWordKeyCode == 0 ? -1 : storedWordKeyCode
        let storedWordMods = defaults.object(forKey: "correctWordHotkeyModifiers") as? Int
        let wordModifiers = storedWordMods.map { UInt(bitPattern: $0) }
            ?? DefaultHotkeys.correctWord.modifiers
        self.correctWordHotkey = HotkeyBinding(keyCode: wordKeyCode, modifiers: wordModifiers)

        if let data = defaults.data(forKey: "appRules"),
           let rules = try? JSONDecoder().decode([AppRule].self, from: data) {
            self.appRules = rules
        } else {
            self.appRules = []
        }

        LoginItem.removeLegacyLaunchAgent()
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
        AppBlacklist.isExcluded(bundleID: bundleID, userRules: appRules)
    }

    private func saveAppRules() {
        if let data = try? JSONEncoder().encode(appRules) {
            defaults.set(data, forKey: "appRules")
        }
    }

    /// Ask the system to launch the app at login, and put the toggle back if it refuses.
    private func updateLaunchAgent() {
        do {
            try LoginItem.setEnabled(autoStartOnLogin)
        } catch {
            print("[MacKeySwitch] Login item update failed: \(error.localizedDescription)")
        }

        // Reflect what the system actually did. Registration fails when the app is not a
        // real bundle (a bare `swift run` build) or when the user has denied it in
        // System Settings, and a toggle that lies about its state is worse than one that
        // snaps back.
        let actual = LoginItem.isEnabled
        guard actual != autoStartOnLogin else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.autoStartOnLogin != actual else { return }
            self.autoStartOnLogin = actual
        }
    }
}

// MARK: - Login Item

/// "Start at login", via the framework Apple actually supports on macOS 13+.
///
/// The previous implementation hand-wrote a LaunchAgent plist into
/// `~/Library/LaunchAgents`. That approach has no way to report failure, wrote an empty
/// file when property-list serialisation returned nil, used a label that did not match the
/// bundle identifier, never ran `launchctl` (so nothing took effect until the next login),
/// and left the plist behind when the app was deleted. `SMAppService` has none of those
/// problems and shows the app in System Settings → General → Login Items.
enum LoginItem {
    private static let legacyPlistPath =
        NSHomeDirectory() + "/Library/LaunchAgents/com.layoutswitcher.plist"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }

    /// Clean up after the hand-rolled LaunchAgent, so upgrading users are not launched
    /// twice — once by the stale plist and once by the registered login item.
    static func removeLegacyLaunchAgent() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyPlistPath) else { return }
        do {
            try fm.removeItem(atPath: legacyPlistPath)
            print("[MacKeySwitch] Removed legacy LaunchAgent plist.")
        } catch {
            print("[MacKeySwitch] Could not remove legacy LaunchAgent: \(error.localizedDescription)")
        }
    }
}
