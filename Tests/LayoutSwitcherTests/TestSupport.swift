import Foundation
@testable import LayoutSwitcher

/// The bundled word lists, read straight from Sources/ rather than through the resource
/// bundle: the test bundle has a different layout than the app, and these tests care
/// about the shipped data itself.
enum Corpus {
    static let english = load("en_words")
    static let ukrainian = load("ua_words")

    private static func load(_ name: String) -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LayoutSwitcherTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/LayoutSwitcher/Resources/\(name).txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

/// A `WordSource` backed by an explicit word list, so detector tests state their inputs
/// instead of depending on what happens to be in the 50k corpus.
struct StubDictionary: WordSource {
    var english: Set<String> = []
    var ukrainian: Set<String> = []

    private func words(for language: Language) -> Set<String> {
        language == .english ? english : ukrainian
    }

    func isWord(_ word: String, language: Language) -> Bool {
        words(for: language).contains(word.lowercased())
    }

    func isPrefix(_ prefix: String, language: Language) -> Bool {
        let lower = prefix.lowercased()
        guard lower.count >= 3 else { return true }
        let head = String(lower.prefix(3))
        return words(for: language).contains { $0.hasPrefix(head) }
    }
}

/// Keycodes for a string typed on a US QWERTY keyboard, as the monitor would buffer them.
/// Mirrors how `KeyMapping.reconstruct` reads them back.
func keycodes(forTyping text: String) -> [(UInt16, Bool)] {
    var result: [(UInt16, Bool)] = []
    for char in text {
        if let entry = KeyMapping.unshifted.first(where: { $0.value.en == char }) {
            result.append((entry.key, false))
        } else if let entry = KeyMapping.shifted.first(where: { $0.value.en == char }) {
            result.append((entry.key, true))
        }
    }
    return result
}
