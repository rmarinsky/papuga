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
    let sourceCore: String?
    let leadingPunctuation: String?
    let trailingPunctuation: String?
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
        let storedToken = BufferedToken(rawText: storedSource, keyCodes: [])
        let storedTarget: String?
        let targetTruncated: Bool
        if let suggestedTarget {
            let targetCore = BufferedToken(rawText: suggestedTarget, keyCodes: []).core
            let truncatedTarget = Self.truncated(targetCore)
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
        self.sourceCore = storedToken.core
        self.leadingPunctuation = storedToken.leadingEdge
        self.trailingPunctuation = storedToken.trailingEdge
        self.suggestedTarget = storedTarget
        self.sourceTruncated = sourceTruncated
        self.targetTruncated = targetTruncated
        self.language = language
        self.bundleID = bundleID
        self.confidence = min(max(confidence, 0), 1)
        self.contextHash = contextHash
    }

    var normalizedSource: String {
        Self.normalizedToken(sourceCore ?? BufferedToken(rawText: source, keyCodes: []).core)
    }

    var normalizedTarget: String? {
        suggestedTarget.map(Self.normalizedToken)
    }

    var renderedSuggestedTarget: String? {
        guard let suggestedTarget else { return nil }
        let sourceToken = BufferedToken(rawText: source, keyCodes: [])
        let leading = leadingPunctuation ?? sourceToken.leadingEdge
        let trailing = trailingPunctuation ?? sourceToken.trailingEdge
        return leading + BufferedToken.normalizedCore(from: suggestedTarget) + trailing
    }

    static func normalizedToken(_ text: String) -> String {
        BufferedToken.normalizedCore(from: text).lowercased()
    }

    static func truncated(_ text: String) -> (String, Bool) {
        guard text.count > maxStoredCharCount else { return (text, false) }
        let visibleCount = max(0, maxStoredCharCount - 1)
        let prefix = String(text.prefix(visibleCount))
        return (prefix + "...", true)
    }


    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case issueType
        case status
        case source
        case sourceCore
        case leadingPunctuation
        case trailingPunctuation
        case suggestedTarget
        case sourceTruncated
        case targetTruncated
        case language
        case bundleID
        case confidence
        case contextHash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        issueType = try container.decode(IssueType.self, forKey: .issueType)
        status = try container.decode(Status.self, forKey: .status)
        source = try container.decode(String.self, forKey: .source)
        suggestedTarget = try container.decodeIfPresent(String.self, forKey: .suggestedTarget)
        sourceTruncated = try container.decode(Bool.self, forKey: .sourceTruncated)
        targetTruncated = try container.decode(Bool.self, forKey: .targetTruncated)
        language = try container.decode(String.self, forKey: .language)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        confidence = try container.decode(Double.self, forKey: .confidence)
        contextHash = try container.decodeIfPresent(String.self, forKey: .contextHash)

        let token = BufferedToken(rawText: source, keyCodes: [])
        sourceCore = try container.decodeIfPresent(String.self, forKey: .sourceCore) ?? token.core
        leadingPunctuation = try container.decodeIfPresent(String.self, forKey: .leadingPunctuation) ?? token.leadingEdge
        trailingPunctuation = try container.decodeIfPresent(String.self, forKey: .trailingPunctuation) ?? token.trailingEdge
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
