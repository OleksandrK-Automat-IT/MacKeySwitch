import Foundation

/// Reconstructed keystrokes must not reach a release build's log. This process sees
/// everything the user types, and a LaunchAgent's stdout lands in a file on disk.
///
/// This is the app's only logging, and it exists in debug builds alone. Release builds
/// write nothing anywhere: a menu-bar agent launched from Finder has no stdout, and NSLog
/// from this ad-hoc-signed bundle was measured not to reach the unified log either. To
/// watch a release-shaped run, build debug and launch the binary from a terminal.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
