import Testing
@testable import LayoutSwitcher

/// Regression suite for a fallback pointed the wrong way.
///
/// Treating "accessibility told us nothing" as unsafe looks like the cautious choice, and
/// it disabled automatic correction everywhere: AXSubrole is optional, ordinary text fields
/// do not set one, and so the common case answered `.unknown` and every correction was
/// skipped. A password field announces itself — through the subrole, or by switching on
/// system-wide secure input. Silence is evidence of an ordinary field.
@Suite struct SecureInputDetectorTests {

    @Test func silenceFromAccessibilityMeansAnOrdinaryField() {
        #expect(SecureInputDetector.resolve(accessibility: .unknown, systemSecureInput: false)
                == .notSecure)
    }

    @Test func anOrdinaryFieldStaysOrdinary() {
        #expect(SecureInputDetector.resolve(accessibility: .notSecure, systemSecureInput: false)
                == .notSecure)
    }

    @Test func aSecureSubroleIsHonoured() {
        #expect(SecureInputDetector.resolve(accessibility: .secure, systemSecureInput: false)
                == .secure)
    }

    @Test(arguments: [SecureFieldState.secure, .notSecure, .unknown])
    func systemSecureInputOverridesEverything(accessibility: SecureFieldState) {
        // The system-wide flag is set by password fields themselves, including in apps
        // that expose nothing to accessibility at all.
        #expect(SecureInputDetector.resolve(accessibility: accessibility, systemSecureInput: true)
                == .secure)
    }

    @Test func resolveNeverReturnsUnknown() {
        // Callers guard on `== .notSecure`, so an unresolved value would silently block them.
        for accessibility in [SecureFieldState.secure, .notSecure, .unknown] {
            for systemFlag in [true, false] {
                let resolved = SecureInputDetector.resolve(
                    accessibility: accessibility, systemSecureInput: systemFlag)
                #expect(resolved != .unknown)
            }
        }
    }
}
