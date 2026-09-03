import Foundation
@testable import LayoutSwitcher

/// The bundled word lists, read straight from Sources/ rather than through the resource
/// bundle: the test bundle has a different layout than the app, and these tests care
/// about the shipped data itself.
enum Corpus {
    static let english = load("en_words")
    static let ukrainian = load("ua_words")
    static let russian = load("ru_words")

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
/// instead of depending on what happens to be in the bundled corpus.
struct StubDictionary: WordSource {
    var english: Set<String> = []
    var ukrainian: Set<String> = []
    var russian: Set<String> = []

    private func words(for language: Language) -> Set<String> {
        switch language {
        case .english: return english
        case .ukrainian: return ukrainian
        case .russian: return russian
        }
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

/// Keystrokes for a string typed on a US QWERTY keyboard, as the monitor would buffer them.
/// Mirrors how `KeyMapping.reconstruct` reads them back.
func keycodes(forTyping text: String, capsLock: Bool = false) -> [Keystroke] {
    var result: [Keystroke] = []
    for char in text {
        if let entry = KeyMapping.unshifted.first(where: { $0.value.en == char }) {
            result.append(Keystroke(keycode: entry.key, shift: false, capsLock: capsLock))
        } else if let entry = KeyMapping.shifted.first(where: { $0.value.en == char }) {
            result.append(Keystroke(keycode: entry.key, shift: true, capsLock: capsLock))
        }
    }
    return result
}

/// The same, keyed on the Ukrainian side of the map: what the buffer holds when a Ukrainian
/// word is typed with the US layout still active.
func keycodes(forTypingUkrainian text: String) -> [Keystroke] {
    text.compactMap { char in
        KeyMapping.unshifted.first { $0.value.ua == char }
            .map { Keystroke(keycode: $0.key) }
    }
}
