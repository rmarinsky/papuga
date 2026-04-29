import Foundation

enum AutoFixDecision {
    static func shouldSkipWord(_ word: String, minLength: Int = 3) -> SkipReason? {
        if word.count < minLength { return .tooShort }
        if word.contains("@") || word.contains("/") || word.contains(".") {
            return .containsForbiddenChars
        }
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
}
