import Testing
@testable import LayoutSwitcher

/// A word manually converted via ⌃⇧X never reaches the automatic corrector's threshold
/// on its own — a brand or an identifier like "github" is not in any dictionary the
/// detector consults, so it scores as if it were gibberish no matter how many times it
/// is fixed by hand. This is the only path that can ever teach the app such a word.
@Suite struct SelectionLearningTests {

    @Test func aSingleConvertedWordIsLearned() {
        #expect(AppDelegate.learnableWord(from: "github", language: .english) == "github")
        #expect(AppDelegate.learnableWord(from: "ґанок", language: .ukrainian) == "ґанок")
    }

    @Test func caseAndSurroundingWhitespaceAreNormalized() {
        #expect(AppDelegate.learnableWord(from: "  GitHub  ", language: .english) == "github")
    }

    @Test func aWholeSentenceIsNotLearnedAsOneWord() {
        // Selection correction works on any selected text, not just a single word — a
        // pasted sentence must not be taught as though it were one giant token.
        #expect(AppDelegate.learnableWord(from: "привіт як справи", language: .ukrainian) == nil)
    }

    @Test func punctuationAndEmptyTextAreRefused() {
        #expect(AppDelegate.learnableWord(from: "3.14", language: .english) == nil)
        #expect(AppDelegate.learnableWord(from: "", language: .english) == nil)
        #expect(AppDelegate.learnableWord(from: "   ", language: .english) == nil)
    }

    @Test func textInTheWrongScriptForItsLanguageIsRefused() {
        // The language named is what the conversion just produced; text that does not
        // even match that script points at a bug upstream, not a word worth learning.
        #expect(AppDelegate.learnableWord(from: "привіт", language: .english) == nil)
        #expect(AppDelegate.learnableWord(from: "hello", language: .ukrainian) == nil)
    }
}
