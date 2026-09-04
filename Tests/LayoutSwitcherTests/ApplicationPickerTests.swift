import Testing
import AppKit
import UniformTypeIdentifiers
@testable import LayoutSwitcher

@Suite @MainActor struct ApplicationPickerTests {

    @Test func itOpensInTheApplicationsFolder() {
        let panel = PerAppTab.applicationPicker()
        #expect(panel.directoryURL?.path == "/Applications")
    }

    @Test func itOffersApplicationsOnly() {
        let panel = PerAppTab.applicationPicker()
        #expect(panel.allowedContentTypes == [UTType.application])
        #expect(panel.canChooseFiles)
        // An .app is a directory on disk; choosing directories would let the panel
        // descend into one instead of returning it.
        #expect(!panel.canChooseDirectories)
        #expect(!panel.allowsMultipleSelection)
    }
}
