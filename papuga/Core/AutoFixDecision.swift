import AppKit
import Foundation

enum AutoFixDecision {
    static func shouldSkipWord(_ word: String, minLength: Int = 3) -> SkipReason? {
        if word.count < minLength { return .tooShort }
        // `.` and `/` are NOT blanket-forbidden: on Ukrainian-PC `.` is `ю`, so a
        // word like `.hsq` typed in EN actually maps to `юрій`. Only skip when
        // the token clearly looks URL/email-like.
        if word.contains("@") { return .containsForbiddenChars }
        if word.contains("://") { return .containsForbiddenChars }
        if hasTLDSuffix(word) { return .containsForbiddenChars }
        if word.first == "#" || word.first == "$" { return .containsForbiddenChars }
        for ch in word where ch.isNumber { return .containsDigits }
        return nil
    }

    private static let knownTLDs: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "ua", "ru",
        "co", "uk", "de", "fr", "us", "ai", "me"
    ]

    private static func hasTLDSuffix(_ word: String) -> Bool {
        guard let dot = word.lastIndex(of: ".") else { return false }
        let suffix = word[word.index(after: dot)...].lowercased()
        return knownTLDs.contains(suffix)
    }

    static func shouldReplace(
        scoreOriginal: Double,
        scoreCandidate: Double,
        threshold: Double
    ) -> Bool {
        return scoreCandidate - scoreOriginal >= threshold
    }

    static func isWordBoundary(keyCode: UInt16, typedString: String) -> Bool {
        // Only whitespace is a universal word boundary. Punctuation like ';' or ','
        // is layout-dependent: ';' on US is `ж` on Ukrainian-PC, ',' on US is `б`
        // on Russian, etc. Treating them as boundaries prematurely flushes the
        // word buffer mid-word and prevents auto-fix from seeing the full token.
        let kVK_Space: UInt16 = 0x31
        let kVK_Return: UInt16 = 0x24
        let kVK_Tab: UInt16 = 0x30
        return keyCode == kVK_Space || keyCode == kVK_Return || keyCode == kVK_Tab
    }

    static func languageHintForLayoutID(_ layoutID: String) -> String {
        let lower = layoutID.lowercased()
        if lower.contains("ukrainian") { return "uk" }
        if lower.contains("russian") { return "ru" }
        if lower.contains("polish") { return "pl" }
        if lower.contains("german") { return "de" }
        if lower.contains("french") { return "fr" }
        if lower.contains("spanish") { return "es" }
        if lower.contains("italian") { return "it" }
        if lower.contains("turkish") { return "tr" }
        if lower.contains("arabic") { return "ar" }
        if lower.contains("hebrew") { return "he" }
        return "en"
    }

    enum SkipReason: String {
        case tooShort
        case containsDigits
        case containsForbiddenChars
    }

    static func isInAllowlist(_ word: String, allowlist: [String]) -> Bool {
        let normalized = word.lowercased()
        return allowlist.contains { $0.lowercased() == normalized }
    }

    /// True when the word is in the system spell-check dictionary for the
    /// given language. Used to short-circuit auto-fix when the user typed a
    /// legitimate word: e.g. `faster` in EN scores ~0.5 as English while the
    /// Cyrillic gibberish candidate `афіеук` scores ~0.99 as Ukrainian (Apple
    /// NL is mostly script detection on short text), which otherwise crosses
    /// the threshold and produces a false positive.
    static func isCorrectlySpelled(_ word: String, language: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return range.location == NSNotFound || range.length == 0
    }
}
