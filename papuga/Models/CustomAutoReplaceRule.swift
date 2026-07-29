import Defaults
import Foundation

struct CustomAutoReplaceRule: Codable, Identifiable, Hashable, Defaults.Serializable {
    let id: UUID
    var source: String
    var target: String
    var createdAt: Date
    var createdFromRecommendation: Bool
    /// `nil` decodes old rules as core-matching; `true` is reserved for exact
    /// layout mappings such as `nfrj; -> також`, where `;` is a letter key.
    var matchesFullToken: Bool?

    init(
        id: UUID = UUID(),
        source: String,
        target: String,
        createdAt: Date = Date(),
        createdFromRecommendation: Bool = false,
        matchesFullToken: Bool = false
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.createdAt = createdAt
        self.createdFromRecommendation = createdFromRecommendation
        self.matchesFullToken = matchesFullToken
    }

    func matches(_ word: String) -> Bool {
        let candidate = matchesFullToken == true
            ? word
            : BufferedToken(rawText: word, keyCodes: []).core
        return source.caseInsensitiveCompare(candidate) == .orderedSame
    }

    func matches(_ token: BufferedToken) -> Bool {
        matches(matchesFullToken == true ? token.rawText : token.core)
    }
}
