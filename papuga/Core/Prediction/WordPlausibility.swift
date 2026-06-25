import Foundation

/// Cheap "is this string a plausible word?" gate. Used to reject garbage
/// suggestions — e.g. a layout conversion of a real Ukrainian word into a
/// consonant-cluster or punctuation soup (`плейрайт → gktqhfqn`, `віджет → dsl;tn`,
/// `репозиторії → htgjpbnjhs]`). A real correction like `кщьфт → roman` passes;
/// gibberish does not.
enum WordPlausibility {
    private static let vowels = Set("aeiouyAEIOUYаеєиіїоуюяёэыАЕЄИІЇОУЮЯЁЭЫ")

    static func isWordLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        // Letters only — no digits, punctuation (`;`, `]`, `.`) or symbols.
        guard trimmed.allSatisfy({ $0.isLetter }) else { return false }
        // Must contain a vowel: kills consonant soup like "gktqhfqn".
        guard trimmed.contains(where: { vowels.contains($0) }) else { return false }
        // No absurd consonant run (real words top out around 5, e.g. "borscht").
        var run = 0
        for ch in trimmed {
            if vowels.contains(ch) { run = 0 } else {
                run += 1
                if run >= 6 { return false }
            }
        }
        return true
    }
}
