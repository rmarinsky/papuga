import Foundation

/// Removes likely secrets / PII from the source words before any of them leave the
/// machine — to the clipboard (paste mode) or over the network (Ollama / OpenRouter).
/// See AI-ASSIST.md §8.2. Pure and deterministic, so it is fully unit-testable, and ON
/// by default. It reuses the same structural heuristics Papuga already trusts in
/// `ProtectedLexiconMatcher`, then adds key-prefix / hex / entropy / length checks.
///
/// Bias: favour recall of secrets over precision. Dropping a weird long token costs the
/// user one un-classified mistake; leaking a key is unrecoverable.
enum SecretScrubber {
    struct Result: Equatable {
        let kept: [String]
        let redactedCount: Int
    }

    /// Partition `words` into the ones safe to send and a count of the ones held back.
    static func scrub(_ words: [String]) -> Result {
        var kept: [String] = []
        var redacted = 0
        for word in words {
            if isLikelySecret(word) { redacted += 1 } else { kept.append(word) }
        }
        return Result(kept: kept, redactedCount: redacted)
    }

    static func isLikelySecret(_ word: String) -> Bool {
        let token = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }

        // Structured tokens Papuga already recognises as "don't touch".
        if ProtectedLexiconMatcher.isEmailLike(token) { return true }
        if ProtectedLexiconMatcher.isURLLike(token) { return true }
        if ProtectedLexiconMatcher.isDomainLike(token) { return true }
        if token.contains("/") || token.contains("\\") { return true }

        // Well-known credential prefixes (API keys, tokens, JWTs).
        let lower = token.lowercased()
        for prefix in secretPrefixes where lower.hasPrefix(prefix) { return true }

        // Long all-hex strings — hashes, raw keys.
        if token.count >= 24, token.allSatisfy(\.isHexDigit) { return true }

        // Long alphanumeric, no-space, high-entropy blobs — opaque keys/tokens.
        if token.count >= 24,
           !token.contains(" "),
           token.rangeOfCharacter(from: .decimalDigits) != nil,
           token.rangeOfCharacter(from: .letters) != nil,
           shannonEntropyBits(token) >= 3.2 {
            return true
        }

        // Any single token this long is not a word someone meant to type.
        if token.count >= 40, !token.contains(" ") { return true }

        return false
    }

    /// Shannon entropy in bits per character.
    static func shannonEntropyBits(_ string: String) -> Double {
        guard !string.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for ch in string { counts[ch, default: 0] += 1 }
        let total = Double(string.count)
        var entropy = 0.0
        for count in counts.values {
            let p = Double(count) / total
            entropy -= p * log2(p)
        }
        return entropy
    }

    private static let secretPrefixes = [
        "sk-", "sk_", "pk-", "pk_", "rk_", "ghp_", "gho_", "ghs_", "github_pat_",
        "xox", "akia", "asia", "aiza", "ya29.", "bearer ", "eyj", "-----begin",
    ]
}
