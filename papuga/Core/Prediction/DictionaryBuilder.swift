import Foundation

/// Builds the per-language SymSpell indexes for the hybrid dictionary:
/// a **bundled base** (frequency lists shipped in the app, for day-1 coverage)
/// **+ a learned overlay** (words the user actually types correctly, which makes
/// their own vocabulary "known" and stops flagging domain jargon).
enum DictionaryBuilder {
    /// Reads a bundled `frequency_<language>.txt` resource ("word<space>count"
    /// per line). Returns [] if the resource isn't bundled yet — the learned
    /// overlay still works on its own.
    static func loadBundledBase(language: String, bundle: Bundle = .main) -> [(String, Int)] {
        guard let url = bundle.url(forResource: "frequency_\(language)", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [(String, Int)] {
        var out: [(String, Int)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let word = parts.first.map(String.init), !word.isEmpty else { continue }
            let count = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 1 : 1
            out.append((word, max(1, count)))
        }
        return out
    }

    /// Word → frequency for the user's correctly-typed corpus. `words` are
    /// (token, language) pairs harvested from replacement history / rule targets
    /// / allowlist (the words the user *produces*, not their mistakes).
    static func learnedFrequencies(from words: [(token: String, language: String)]) -> [String: [(String, Int)]] {
        var byLang: [String: [String: Int]] = [:]
        for (raw, language) in words {
            let token = MistakeObservation.normalizedToken(raw)
            guard token.count >= 2, !token.contains(where: \.isWhitespace) else { continue }
            byLang[language, default: [:]][token, default: 0] += 1
        }
        return byLang.mapValues { counts in counts.map { ($0.key, $0.value) } }
    }

    /// Combine base + learned into one SymSpell per language. Learned counts are
    /// weighted up so the user's own words rank ahead of generic ones.
    static func build(
        base: [String: [(String, Int)]],
        learned: [String: [(String, Int)]],
        learnedWeight: Int = 1000,
        maxEditDistance: Int = 2,
        prefixLength: Int = 7
    ) -> [String: SymSpell] {
        var result: [String: SymSpell] = [:]
        let languages = Set(base.keys).union(learned.keys)
        for language in languages {
            let symSpell = SymSpell(maxDictionaryEditDistance: maxEditDistance, prefixLength: prefixLength)
            for (word, count) in base[language] ?? [] {
                symSpell.createDictionaryEntry(word.lowercased(), count: count)
            }
            for (word, count) in learned[language] ?? [] {
                symSpell.createDictionaryEntry(word.lowercased(), count: count * learnedWeight)
            }
            result[language] = symSpell
        }
        return result
    }
}
