import Testing
@testable import LayoutSwitcher

@Suite struct DictionaryMutationTests {
    @Test func aQueuedRebuildCannotEraseANewerCustomWord() {
        let dictionary = DictionaryManager()

        dictionary.rebuildAsync(
            customEnglishWords: ["oldercustomword"],
            customUkrainianWords: [],
            englishPaths: [],
            ukrainianPaths: []
        )

        // This synchronous mutation is also a queue barrier: it must run after the rebuild
        // that was requested first, rather than being overtaken and erased by it.
        dictionary.addCustomEnglishWords(["newercustomword"])

        #expect(dictionary.isEnglishWord("oldercustomword"))
        #expect(dictionary.isEnglishWord("newercustomword"))
    }
}
