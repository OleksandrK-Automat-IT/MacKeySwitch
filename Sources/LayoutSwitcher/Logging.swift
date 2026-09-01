import Foundation

/// Reconstructed keystrokes must not reach a release build's log. This process sees
/// everything the user types, and a LaunchAgent's stdout lands in a file on disk.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

/// Appends a line to `~/Library/Logs/MacKeySwitch.log`.
///
/// A menu-bar app launched from Finder has nowhere to send stdout, and NSLog from this
/// ad-hoc-signed bundle does not reach the unified log either — verified by looking: the
/// process emits a thousand framework lines and not one of its own. That left every
/// failure in this app invisible, which is why three separate faults here could only be
/// guessed at. A file is the one channel that works however the app was started.
///
/// Reserved for events that happen a handful of times: launch, shortcut registration, a
/// refused correction. Never per keystroke.
func appLog(_ message: @autoclosure () -> String) {
    let line = "\(Date()) \(message())\n"
    AppLogFile.shared.append(line)
}

private final class AppLogFile {
    static let shared = AppLogFile()

    private let url: URL?
    private let lock = NSLock()
    /// Rewritten from scratch once it passes this, so it cannot grow without bound.
    private static let maxBytes = 512 * 1024

    private init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Logs")
        url = logs?.appendingPathComponent("MacKeySwitch.log")
        if let logs = logs {
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        }
    }

    func append(_ line: String) {
        guard let url = url, let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }

        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > Self.maxBytes {
            try? manager.removeItem(at: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
