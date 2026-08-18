import Foundation

/// Locates the SwiftPM resource bundle without ever calling `fatalError`.
///
/// `Bundle.module`, the accessor SwiftPM generates, traps when it cannot find the bundle —
/// which is exactly what happens if the app is assembled by hand rather than by SwiftPM and
/// the bundle is not where the accessor expects. A menu-bar app that dies on launch because
/// a word list moved is a bad trade, so the search is done here and failure is a `nil`.
enum ResourceBundle {
    private static let bundleName = "LayoutSwitcher_LayoutSwitcher.bundle"

    /// The resource bundle, or nil when it cannot be found in any of the usual places.
    static let main: Bundle? = {
        // 1. SPM default: next to the executable.
        let mainPath = Bundle.main.bundleURL.appendingPathComponent(bundleName).path
        if let bundle = Bundle(path: mainPath) { return bundle }

        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])

        // 2. Inside Contents/Resources/ (.app bundle layout).
        let appResourcesPath = execURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent(bundleName).path
        if let bundle = Bundle(path: appResourcesPath) { return bundle }

        // 3. Next to the executable directly.
        let siblingPath = execURL.deletingLastPathComponent()
            .appendingPathComponent(bundleName).path
        if let bundle = Bundle(path: siblingPath) { return bundle }

        return nil
    }()

    /// Find a resource file, checking the bundle and then the loose layouts the installer
    /// has used over time.
    static func url(forResource name: String, extension ext: String) -> URL? {
        if let bundle = main, let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }

        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])

        let siblingURL = execURL.deletingLastPathComponent()
            .appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: siblingURL.path) {
            return siblingURL
        }

        let resourcesURL = execURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: resourcesURL.path) {
            return resourcesURL
        }

        return nil
    }
}
