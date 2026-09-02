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

    /// Upper bound on one accessibility round trip, in seconds.
    private static let messagingTimeout: Float = 0.05

    /// macOS-wide secure input mode, which password fields switch on. A cheap read, safe to
    /// consult on every keystroke.
    static var isSystemSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// Ask accessibility what the focused element is. More precise than the system flag —
    /// some fields are marked without enabling secure input mode — but it is an IPC round
    /// trip, so call it per word rather than per keystroke.
    ///
    /// Returns `.unknown` freely: most ordinary text fields have no subrole at all, and
    /// plenty of apps answer nothing useful. Interpreting that is `resolve`'s job.
    static func focusedFieldState() -> SecureFieldState {
        guard AXIsProcessTrusted() else { return .unknown }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return .unknown
        }

        // Asking the application element rather than the system-wide one: the system-wide
        // focused-element query is the less reliable of the two, and a failure here reads
        // as "no answer", which must never be mistaken for "password field".
        let application = AXUIElementCreateApplication(pid)
        // Cap how long a slow app may hold this query. The default is effectively
        // unbounded, and an Electron app under load was holding it for half a second —
        // on the main thread, at every word boundary. A timed-out query reads as
        // .unknown, which resolve() treats as an ordinary field; the system-wide secure
        // input flag, checked first and cheaply, stays the authority for password fields.
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedValue = focused,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return .unknown
        }

        let element = focusedValue as! AXUIElement  // type ID checked immediately above
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSubroleAttribute as CFString, &subrole) == .success,
              let subroleName = subrole as? String
        else {
            // Subroles are optional, and a plain text field or text area simply has none.
            return .unknown
        }

        return subroleName == (kAXSecureTextFieldSubrole as String) ? .secure : .notSecure
    }

    /// Turn the two signals into an answer callers can act on. Never returns `.unknown`.
    ///
    /// The direction of the fallback matters, and getting it backwards is what broke
    /// automatic correction everywhere: treating "accessibility said nothing" as unsafe
    /// blocks every correction, because saying nothing is the normal case — AXSubrole is
    /// optional and ordinary text fields do not set it. Secure fields are the ones that
    /// announce themselves, through the subrole or by switching on secure input mode; the
    /// absence of both is evidence of an ordinary field, not of an unreadable one.
    static func resolve(accessibility: SecureFieldState, systemSecureInput: Bool) -> SecureFieldState {
        if systemSecureInput { return .secure }
        return accessibility == .secure ? .secure : .notSecure
    }

    /// Combined verdict for the field that has focus right now.
    static func current() -> SecureFieldState {
        // Checked first because it is cheap and decisive; the accessibility round trip is
        // skipped entirely when the system already says a password field has focus.
        if isSystemSecureInputEnabled { return .secure }
        return resolve(accessibility: focusedFieldState(), systemSecureInput: false)
    }
}
