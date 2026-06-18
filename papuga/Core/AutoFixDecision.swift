import AppKit
import Foundation

struct SpellingTypoGuardAssessment: Equatable {
    let shouldSuppressAutoReplace: Bool
    let suggestion: String?
    let editDistance: Int?
}

enum AutoFixDecision {
    static func shouldSkipWord(_ word: String, minLength: Int = 3) -> SkipReason? {
        if word.count < minLength { return .tooShort }
        // `.` and `/` are NOT blanket-forbidden: on Ukrainian-PC `.` is `ю`, so a
        // word like `.hsq` typed in EN actually maps to `юрій`. Only skip when
        // the token clearly looks URL/email-like.
        if ProtectedLexiconMatcher.isEmailLike(word) { return .containsForbiddenChars }
        if ProtectedLexiconMatcher.isURLLike(word) { return .containsForbiddenChars }
        if ProtectedLexiconMatcher.isDomainLike(word) { return .containsForbiddenChars }
        if word.first == "#" || word.first == "$" { return .containsForbiddenChars }
        for ch in word where ch.isNumber { return .containsDigits }
        return nil
    }

    static func shouldReplace(
        scoreOriginal: Double,
        scoreCandidate: Double,
        threshold: Double
    ) -> Bool {
        return scoreCandidate - scoreOriginal >= threshold
    }

    static func shouldSuggestPhraseLayoutMistake(
        original: String,
        candidate: String,
        targetLanguage: String,
        scoreCandidate: Double
    ) -> Bool {
        let originalWords = words(in: original)
        let candidateWords = words(in: candidate).map { $0.lowercased() }
        guard targetLanguage.lowercased() == "en",
              originalWords.count >= 3,
              candidateWords.count >= 3,
              scoreCandidate >= 0.70,
              isCrossScriptConversion(original: original, candidate: candidate),
              containsCyrillicLetter(original),
              containsLatinLetter(candidate)
        else {
            return false
        }

        let commonHits = candidateWords.filter { commonEnglishPhraseWords.contains($0) }.count
        let hasMeaningfulWord = candidateWords.contains { $0.count >= 5 }
        return commonHits >= 2 && hasMeaningfulWord
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
    /// 1-entry memo. Per word boundary, `evaluateAndMaybeFix` first calls this for the
    /// `originalIsRealWord` guard and the spelling-typo guard then calls it again for the same
    /// (word, language); the memo serves the second call instead of issuing a duplicate synchronous
    /// NSSpellChecker IPC round-trip. All callers run on the main actor. Correctness-neutral: it
    /// only short-circuits an immediately-repeated identical query.
    private static var lastSpellCheck: (word: String, language: String, result: Bool)?

    static func isCorrectlySpelled(_ word: String, language: String) -> Bool {
        if let memo = lastSpellCheck, memo.word == word, memo.language == language {
            return memo.result
        }
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        let result = range.location == NSNotFound || range.length == 0
        lastSpellCheck = (word, language, result)
        return result
    }

    /// Prevents layout auto-fix from punishing normal spelling mistakes.
    ///
    /// Example: `fster` in an English layout is likely a typo for `faster`;
    /// AppleNL may still score the Ukrainian-layout candidate very highly
    /// because it mostly sees Cyrillic script. In that case we should record a
    /// spelling observation, not mutate the user's word into another layout.
    static func spellingTypoGuardAssessment(
        original: String,
        candidate: String,
        language: String,
        minWordLength: Int = 4,
        maxEditDistance: Int = 1,
        isKnownCorrect: ((String, String) -> Bool)? = nil,
        suggestions: ((String, String) -> [String])? = nil
    ) -> SpellingTypoGuardAssessment {
        let word = normalizedSpellcheckToken(original)
        let spellcheck = isKnownCorrect ?? { word, language in
            AutoFixDecision.isCorrectlySpelled(word, language: language)
        }
        guard word.count >= minWordLength,
              maxEditDistance >= 0,
              scriptMatches(language: language, word: word),
              isCrossScriptConversion(original: word, candidate: candidate),
              !spellcheck(word, language)
        else {
            return SpellingTypoGuardAssessment(
                shouldSuppressAutoReplace: false,
                suggestion: nil,
                editDistance: nil
            )
        }

        let guesses = (suggestions ?? spellingSuggestions)(word, language)

        let best = guesses
            .prefix(8)
            .map { suggestion in
                (suggestion, spellingEditDistance(word.lowercased(), suggestion.lowercased()))
            }
            .min { lhs, rhs in lhs.1 < rhs.1 }

        guard let best,
              best.1 <= maxEditDistance
        else {
            return SpellingTypoGuardAssessment(
                shouldSuppressAutoReplace: false,
                suggestion: best?.0,
                editDistance: best?.1
            )
        }

        return SpellingTypoGuardAssessment(
            shouldSuppressAutoReplace: true,
            suggestion: best.0,
            editDistance: best.1
        )
    }

    private static func spellingSuggestions(for word: String, language: String) -> [String] {
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.guesses(
            forWordRange: range,
            in: word,
            language: language,
            inSpellDocumentWithTag: 0
        ) ?? []
    }

    private static func normalizedSpellcheckToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}<>\"'`“”‘’"))
    }

    private static func words(in text: String) -> [String] {
        text.split { !$0.isLetter }.map(String.init)
    }

    private static func scriptMatches(language: String, word: String) -> Bool {
        let hasLatin = containsLatinLetter(word)
        let hasCyrillic = containsCyrillicLetter(word)
        let normalizedLanguage = language.lowercased()

        if normalizedLanguage == "uk" || normalizedLanguage == "ru" {
            return hasCyrillic && !hasLatin
        }

        return hasLatin && !hasCyrillic
    }

    private static func isCrossScriptConversion(original: String, candidate: String) -> Bool {
        let originalLatin = containsLatinLetter(original)
        let originalCyrillic = containsCyrillicLetter(original)
        let candidateLatin = containsLatinLetter(candidate)
        let candidateCyrillic = containsCyrillicLetter(candidate)

        return (originalLatin && candidateCyrillic && !candidateLatin)
            || (originalCyrillic && candidateLatin && !candidateCyrillic)
    }

    private static func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
        }
    }

    private static func containsCyrillicLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0400...0x04FF).contains(Int(scalar.value))
        }
    }

    private static func spellingEditDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var distance = Array(
            repeating: Array(repeating: 0, count: b.count + 1),
            count: a.count + 1
        )

        for i in 0...a.count {
            distance[i][0] = i
        }
        for j in 0...b.count {
            distance[0][j] = j
        }

        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                distance[i][j] = min(
                    distance[i - 1][j] + 1,
                    distance[i][j - 1] + 1,
                    distance[i - 1][j - 1] + cost
                )

                if i > 1,
                   j > 1,
                   a[i - 1] == b[j - 2],
                   a[i - 2] == b[j - 1] {
                    distance[i][j] = min(distance[i][j], distance[i - 2][j - 2] + 1)
                }
            }
        }

        return distance[a.count][b.count]
    }

    private static let commonEnglishPhraseWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "can", "do",
        "for", "from", "have", "i", "if", "in", "is", "it", "my", "not",
        "of", "on", "or", "our", "that", "the", "this", "to", "we", "what",
        "when", "with", "you", "your"
    ]
}
