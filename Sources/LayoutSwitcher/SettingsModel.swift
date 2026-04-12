import Foundation
import Combine

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

        /// Score threshold — lower = more aggressive switching
        var threshold: Double {
            switch self {
            case .low: return 20.0
            case .medium: return 10.0
            case .high: return 5.0
            case .veryHigh: return 2.0
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
        didSet { defaults.set(exceptionWords, forKey: "exceptionWords") }
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

        self.exceptionWords = defaults.object(forKey: "exceptionWords") as? [String] ?? []

        self.customEnglishDictionaryPaths = defaults.object(forKey: "customEnglishDictionaryPaths") as? [String] ?? []
        self.customUkrainianDictionaryPaths = defaults.object(forKey: "customUkrainianDictionaryPaths") as? [String] ?? []

        self.totalCorrections = defaults.object(forKey: "totalCorrections") as? Int ?? 0

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
        if !exceptionWords.contains(lower) {
            exceptionWords.append(lower)
            print("[LayoutSwitcher] Self-learning: added '\(lower)' to exceptions")
        }
    }

    func isException(_ word: String) -> Bool {
        exceptionWords.contains(word.lowercased())
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
