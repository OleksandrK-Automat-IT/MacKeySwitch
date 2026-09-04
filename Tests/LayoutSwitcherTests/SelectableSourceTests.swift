import Testing
import Carbon
@testable import LayoutSwitcher

/// The menu offers exactly the layouts already added in System Settings — no more, and
/// nothing that is not a layout.
@Suite struct SelectableSourceTests {

    @Test func itListsTheLayoutsTheSystemHasEnabled() {
        let sources = InputSourceManager.selectableKeyboardSources()
        #expect(!sources.isEmpty, "at least the layout being typed in right now")
        for source in sources {
            #expect(!source.id.isEmpty)
            #expect(!source.name.isEmpty, "\(source.id) has no name to show")
        }
        #expect(Set(sources.map(\.id)).count == sources.count, "no duplicates")
    }

    @Test func theActiveLayoutIsOneOfThem() {
        // Otherwise the menu could show no tick at all, or tick the wrong row.
        let current = InputSourceManager.currentInputSourceID()
        #expect(InputSourceManager.selectableKeyboardSources().contains { $0.id == current })
    }

    @Test func palettesAndInputMethodsAreLeftOut() {
        // Emoji & Symbols and the character viewer live in the same list and are not
        // layouts; offering them would switch the user into something they cannot type in.
        let ids = InputSourceManager.selectableKeyboardSources().map(\.id)
        for id in ids {
            #expect(!id.contains("CharacterPalette"), "\(id)")
            #expect(!id.contains("EmojiFunctionRow"), "\(id)")
            #expect(!id.contains("PressAndHold"), "\(id)")
        }
    }
}
