import ApplicationServices
import Carbon
import Cocoa

/// Whether the focused field hides what is typed into it.
enum SecureFieldState {
    case secure
    case notSecure
    /// The app exposes nothing usable. Callers that can afford caution treat this as unsafe.
    case unknown
}

/// Detects password fields so the monitor can leave them alone.
///
/// This replaces guessing from the shape of the characters. A heuristic cannot know whether
/// a field is a password — it only knows the text has mixed case and a digit — and getting
/// it wrong means mangling a credential the user cannot see to repair.
///
/// Modelled on SwitchFix (github.com/rundax/SwitchFix, MIT): ask accessibility for the
/// focused element's subrole, and fall back to the system-wide secure input flag for apps
/// that expose nothing.
enum SecureInputDetector {

    /// macOS-wide secure input mode, which password fields switch on. A cheap read, safe to
    /// consult on every keystroke.
    static var isSystemSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// Ask accessibility what the focused element is. More precise than the system flag —
    /// some fields are marked without enabling secure input mode — but it is an IPC round
    /// trip, so call it per word rather than per keystroke.
    static func focusedFieldState() -> SecureFieldState {
        guard AXIsProcessTrusted() else { return .unknown }

        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedValue = focused,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return .unknown
        }

        let element = focusedValue as! AXUIElement  // type ID checked immediately above
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSubroleAttribute as CFString, &subrole) == .success,
              let subroleName = subrole as? String
        else {
            // No subrole exposed — the app may still be showing a password field.
            return .unknown
        }

        return subroleName == (kAXSecureTextFieldSubrole as String) ? .secure : .notSecure
    }

    /// Combined verdict. The system flag is authoritative when set; otherwise defer to
    /// accessibility.
    static func current() -> SecureFieldState {
        if isSystemSecureInputEnabled { return .secure }
        return focusedFieldState()
    }
}
