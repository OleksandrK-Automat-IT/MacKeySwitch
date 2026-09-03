import Testing
import AppKit
@testable import LayoutSwitcher

/// The undo shortcut used to live in two separate `@Published` properties, and the observer
/// that registered it read them back off the model. `@Published` emits *before* the stored
/// property is updated, so that read always returned the previous value: recording ⌥⌘K
/// registered ⌃⇧K, and clearing the shortcut re-registered the old one instead of removing
/// it. Keeping keycode and modifiers in one value is what makes the stale read impossible,
/// so these tests pin the shape as much as the behaviour.
@Suite struct HotkeyBindingTests {

    @Test func aBindingCarriesItsKeyAndModifiersTogether() {
        let optionCommand = NSEvent.ModifierFlags([.option, .command]).rawValue
        let binding = HotkeyBinding(keyCode: 0x28, modifiers: optionCommand) // K

        // Both halves survive as one value — there is no window in which the new key is
        // paired with the old modifiers.
        #expect(binding.keyCode == 0x28)
        #expect(binding.modifiers == optionCommand)
        #expect(binding.description == "\u{2325}\u{2318}K")
    }

    @Test func theDisabledBindingIsNotEnabled() {
        #expect(!HotkeyBinding.disabled.isEnabled)
        // Compared against the localized string, not the English literal: the label follows
        // the interface language, and LocalizationTests is what pins its actual wording.
        #expect(HotkeyBinding.disabled.description == L("hotkey.disabled"))
        // Whatever language it is in, it must not render as a key glyph.
        #expect(HotkeyBinding.disabled.description != HotkeyBinding.keyCodeLabel(0))
    }

    /// Keycode 0 is the letter 'A', not a sentinel: recording ⌃⌥A used to store keyCode 0
    /// and read back as "disabled". The marker is -1 now, so an 'A' binding must register.
    @Test func aBindingOnTheLetterAIsEnabled() {
        let controlOption = NSEvent.ModifierFlags([.control, .option]).rawValue
        let binding = HotkeyBinding(keyCode: 0, modifiers: controlOption)
        #expect(binding.isEnabled)
        #expect(binding.description == "\u{2303}\u{2325}A")
        #expect(SettingsModel.normalizedStoredKeyCode(0, modifiers: controlOption) == 0)
    }

    @Test func onlyTheLegacyZeroZeroBindingMigratesToDisabled() {
        #expect(SettingsModel.normalizedStoredKeyCode(0, modifiers: 0) == -1)
        #expect(SettingsModel.normalizedStoredKeyCode(6, modifiers: 0) == 6)
    }

    @Test func theDefaultBindingReadsAsControlShiftZ() {
        let binding = HotkeyBinding(
            keyCode: 0x06,
            modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue
        )
        #expect(binding.isEnabled)
        #expect(binding.description == "\u{2303}\u{21E7}Z")
    }

    @Test func modifiersAreRenderedInTheOrderMacOSShowsThem() {
        let all = NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue
        let binding = HotkeyBinding(keyCode: 0x06, modifiers: all)
        // ⌃⌥⇧⌘ — the order Apple's own menus use, regardless of insertion order.
        #expect(binding.description == "\u{2303}\u{2325}\u{21E7}\u{2318}Z")
    }

    @Test func anUnknownKeycodeStillProducesALabel() {
        let binding = HotkeyBinding(keyCode: 0x5A, modifiers: NSEvent.ModifierFlags.control.rawValue)
        #expect(binding.description == "\u{2303}Key90")
    }

    @Test func everyLabelledKeycodeGivesASingleLineLabel() {
        // The menu item only accepts a one-character key equivalent, and falls back to a
        // blank one otherwise — an empty or multi-line label would render as a stray glyph.
        for keycode in UInt16(0)...UInt16(0x7F) {
            let label = HotkeyBinding.keyCodeLabel(keycode)
            #expect(!label.isEmpty)
            #expect(!label.contains("\n"))
        }
    }
}

/// Three global shortcuts now ship enabled by default. Carbon refuses to register a
/// duplicate key-and-modifier combination, and it does so quietly — the second shortcut
/// simply never fires — so a clash between defaults would ship as a dead feature.
@Suite struct DefaultHotkeyTests {

    @Test func defaultsAreDistinct() {
        let defaults = SettingsModel.DefaultHotkeys.all
        for (index, binding) in defaults.enumerated() {
            for other in defaults[(index + 1)...] {
                #expect(binding != other, "two shortcuts default to \(binding.description)")
            }
        }
    }

    @Test func everyDefaultIsEnabled() {
        for binding in SettingsModel.DefaultHotkeys.all {
            #expect(binding.isEnabled, "\(binding.description) defaults to disabled")
        }
    }

    @Test func everyDefaultCarriesANonShiftModifier() {
        // A bare key, or one held only with Shift, would swallow ordinary typing.
        let nonShift = NSEvent.ModifierFlags([.control, .option, .command])
        for binding in SettingsModel.DefaultHotkeys.all {
            let flags = NSEvent.ModifierFlags(rawValue: binding.modifiers)
            #expect(!flags.isDisjoint(with: nonShift),
                    "\(binding.description) would intercept plain typing")
        }
    }
}
