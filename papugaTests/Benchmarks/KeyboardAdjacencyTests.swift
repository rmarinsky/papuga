import XCTest
import Carbon.HIToolbox
@testable import papuga

/// A spell checker that only knows a fixed set of correct words — lets the
/// keystroke-model test assert a specific fat-finger correction deterministically.
final class DictionarySpellChecker: SpellCheckingClient {
    private let correct: Set<String>
    init(correct: Set<String>) { self.correct = Set(correct.map { $0.lowercased() }) }
    func isMisspelled(_ word: String, language: String) -> Bool { !correct.contains(word.lowercased()) }
    func guesses(for word: String, language: String) -> [String] { [] }
}

final class KeyboardAdjacencyTests: XCTestCase {

    func test_grid_neighbours_arePhysicallyAdjacent() {
        let s = KeyboardAdjacency.neighbours(of: UInt16(kVK_ANSI_S))
        // S sits between A and D, under W/E, over Z/X.
        for code in [kVK_ANSI_A, kVK_ANSI_D, kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_Z, kVK_ANSI_X] {
            XCTAssertTrue(s.contains(UInt16(code)), "S should neighbour \(code)")
        }
        // Not two keys away.
        XCTAssertFalse(s.contains(UInt16(kVK_ANSI_F)), "S should not neighbour F")
        XCTAssertFalse(s.contains(UInt16(kVK_ANSI_R)), "S should not neighbour R")

        // Adjacency is symmetric.
        for (code, near) in KeyboardAdjacency.neighbours {
            for n in near {
                XCTAssertTrue(KeyboardAdjacency.neighbours(of: n).contains(code),
                              "adjacency must be symmetric (\(code) ↔ \(n))")
            }
        }
        // Every printable key has a few neighbours (sanity).
        XCTAssertGreaterThanOrEqual(KeyboardAdjacency.neighbours(of: UInt16(kVK_ANSI_G)).count, 4)
    }

    @MainActor
    func test_analyzer_emits_fatFinger_correction() throws {
        let layoutManager = LayoutManager()
        let hasEnglish = layoutManager.orderedLayouts()
            .contains { AutoFixDecision.languageHintForLayoutID($0) == "en" }
        try XCTSkipUnless(hasEnglish, "needs a US English layout on the test machine")

        // "hwllo" → "hello" by pressing E instead of the adjacent W.
        let analyzer = MistakeSuggestionAnalyzer(spellChecker: DictionarySpellChecker(correct: ["hello"]))
        let candidates = analyzer.candidates(
            for: "hwllo", language: "en", recordedTargets: [],
            layoutManager: layoutManager, limit: 6
        )
        XCTAssertTrue(
            candidates.contains { $0.kind == .keyboardAdjacency && $0.text == "hello" },
            "expected a keyboard-adjacency candidate 'hello', got \(candidates.map { "\($0.kind.rawValue):\($0.text)" })"
        )
    }
}
