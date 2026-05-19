import Defaults
import Foundation

struct CustomAutoReplaceRule: Codable, Identifiable, Hashable, Defaults.Serializable {
    let id: UUID
    var source: String
    var target: String
    var createdAt: Date
    var createdFromRecommendation: Bool

    init(
        id: UUID = UUID(),
        source: String,
        target: String,
        createdAt: Date = Date(),
        createdFromRecommendation: Bool = false
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.createdAt = createdAt
        self.createdFromRecommendation = createdFromRecommendation
    }

    func matches(_ word: String) -> Bool {
        source.caseInsensitiveCompare(word) == .orderedSame
    }
}
