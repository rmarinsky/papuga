import Foundation

struct MistakeObservation: Codable, Identifiable, Equatable {
    static let maxStoredCharCount = 80

    enum IssueType: String, Codable, CaseIterable, Identifiable {
        case spelling
        case manualCorrection
        case grammar
        case layoutCandidate

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .spelling: return "Орфографія"
            case .manualCorrection: return "Ручне виправлення"
            case .grammar: return "Граматика beta"
            case .layoutCandidate: return "Розкладка"
            }
        }

        var systemImage: String {
            switch self {
            case .spelling: return "text.magnifyingglass"
            case .manualCorrection: return "arrow.uturn.backward.circle"
            case .grammar: return "text.badge.checkmark"
            case .layoutCandidate: return "keyboard"
            }
        }
    }

    enum Status: String, Codable, CaseIterable {
        case open
        case dismissed
        case convertedToRule
        case addedToDictionary
    }

    let id: UUID
    let timestamp: Date
    let issueType: IssueType
    let status: Status
    let source: String
    let suggestedTarget: String?
    let sourceTruncated: Bool
    let targetTruncated: Bool
    let language: String
    let bundleID: String?
    let confidence: Double
    let contextHash: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        issueType: IssueType,
        status: Status = .open,
        source: String,
        suggestedTarget: String? = nil,
        language: String,
        bundleID: String? = nil,
        confidence: Double,
        contextHash: String? = nil
    ) {
        let (storedSource, sourceTruncated) = Self.truncated(source)
        let storedTarget: String?
        let targetTruncated: Bool
        if let suggestedTarget {
            let truncatedTarget = Self.truncated(suggestedTarget)
            storedTarget = truncatedTarget.0
            targetTruncated = truncatedTarget.1
        } else {
            storedTarget = nil
            targetTruncated = false
        }
        self.id = id
        self.timestamp = timestamp
        self.issueType = issueType
        self.status = status
        self.source = storedSource
        self.suggestedTarget = storedTarget
        self.sourceTruncated = sourceTruncated
        self.targetTruncated = targetTruncated
        self.language = language
        self.bundleID = bundleID
        self.confidence = min(max(confidence, 0), 1)
        self.contextHash = contextHash
    }

    var normalizedSource: String {
        Self.normalizedToken(source)
    }

    var normalizedTarget: String? {
        suggestedTarget.map(Self.normalizedToken)
    }

    static func normalizedToken(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
    }

    static func truncated(_ text: String) -> (String, Bool) {
        guard text.count > maxStoredCharCount else { return (text, false) }
        let visibleCount = max(0, maxStoredCharCount - 1)
        let prefix = String(text.prefix(visibleCount))
        return (prefix + "...", true)
    }
}

enum MistakeObservationRetention: String, CaseIterable {
    case oneWeek
    case oneMonth
    case threeMonths

    var title: String {
        switch self {
        case .oneWeek: return "7 днів"
        case .oneMonth: return "30 днів"
        case .threeMonths: return "90 днів"
        }
    }

    var timeInterval: TimeInterval {
        switch self {
        case .oneWeek: return 7 * 24 * 60 * 60
        case .oneMonth: return 30 * 24 * 60 * 60
        case .threeMonths: return 90 * 24 * 60 * 60
        }
    }
}
