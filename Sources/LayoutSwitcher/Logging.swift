import Foundation

/// Reconstructed keystrokes must not reach a release build's log. This process sees
/// everything the user types, and a LaunchAgent's stdout lands in a file on disk.
@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
