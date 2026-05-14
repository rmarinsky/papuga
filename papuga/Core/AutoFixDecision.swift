import AppKit
import Foundation

enum AutoFixDecision {
    /// Tokens at or below this length are decided by dictionary lookup only —
    /// no statistical language scorer can produce a reliable signal on 2–3
    /// characters (Apple NL collapses to script detection at that size, and a
    /// char-trigram model can't even form a trigram from 2 chars).
    static let shortTokenMaxLength = 3

    static func shouldSkipWord(_ word: String, minLength: Int = 2) -> SkipReason? {
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

    /// Asks NSSpellChecker for the best replacement for a misspelled word in
    /// the given language. Used when the layout-converted candidate is itself
    /// misspelled — e.g. user types `руддз` in UA layout intending `hello` but
    /// fat-fingers it; convert produces `hellp`; this returns `hello`.
    /// Returns nil if no usable suggestion exists or the only suggestion equals
    /// the input.
    static func correctTypo(in candidate: String, language: String) -> String? {
        guard !candidate.isEmpty else { return nil }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (candidate as NSString).length)
        guard let guesses = checker.guesses(
            forWordRange: range,
            in: candidate,
            language: language,
            inSpellDocumentWithTag: 0
        ) else {
            return nil
        }
        for guess in guesses {
            let trimmed = guess.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.lowercased() == candidate.lowercased() { continue }
            return trimmed
        }
        return nil
    }

    /// Tight gate so spell-correction only fires for near-misses. Rejects
    /// suggestions that change too many characters or the word length too
    /// much, which keeps the path from inventing words the user didn't intend.
    static func acceptableCorrection(of candidate: String, to suggestion: String) -> Bool {
        guard !candidate.isEmpty, !suggestion.isEmpty else { return false }
        if abs(candidate.count - suggestion.count) > 1 { return false }
        let maxEdits = candidate.count <= 5 ? 1 : 2
        return levenshtein(candidate.lowercased(), suggestion.lowercased(), limit: maxEdits) <= maxEdits
    }

    /// Levenshtein with early termination once every cell in the current row
    /// exceeds `limit` — keeps the cost bounded for the typical 4–15 char
    /// words we see at the auto-fix boundary.
    static func levenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var prev = Array(0...bChars.count)
        var curr = [Int](repeating: 0, count: bChars.count + 1)
        let cap = limit + 1

        for i in 1...aChars.count {
            curr[0] = i
            var rowMin = curr[0]
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
                if curr[j] < rowMin { rowMin = curr[j] }
            }
            if rowMin > limit { return cap }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}
