import Foundation

enum Recommendation: Identifiable, Hashable {
    case addWordToAllowlist(word: String, undoCount: Int, tier: Int)
    case createCustomRule(source: String, target: String, count: Int, tier: Int)
    case addAppToBlocklist(bundleID: String, undoCount: Int, tier: Int)

    var id: String { dedupKey }

    var dedupKey: String {
        switch self {
        case .addWordToAllowlist(let word, _, _):
            return "allowlist:\(word.lowercased())"
        case .createCustomRule(let source, let target, _, _):
            return "rule:\(source.lowercased())→\(target.lowercased())"
        case .addAppToBlocklist(let bundleID, _, _):
            return "blocklist:\(bundleID.lowercased())"
        }
    }

    var tier: Int {
        switch self {
        case .addWordToAllowlist(_, _, let tier),
             .createCustomRule(_, _, _, let tier),
             .addAppToBlocklist(_, _, let tier):
            return tier
        }
    }

    var count: Int {
        switch self {
        case .addWordToAllowlist(_, let count, _),
             .createCustomRule(_, _, let count, _),
             .addAppToBlocklist(_, let count, _):
            return count
        }
    }
}

enum RecommendationEngine {
    static let fibonacciThresholds = [3, 5, 8, 13, 21]
    static let minBlocklistThreshold = 8

    static func tier(for count: Int, thresholds: [Int] = fibonacciThresholds) -> Int {
        var resolved = 0
        for (index, threshold) in thresholds.enumerated() where count >= threshold {
            resolved = index + 1
        }
        return resolved
    }

    static func compute(
        from history: [ReplacementHistoryEntry],
        allowlist: [String],
        blocklist: [String],
        customRules: [CustomAutoReplaceRule],
        dismissed: [String]
    ) -> [Recommendation] {
        var recs: [Recommendation] = []

        let allowlistLower = Set(allowlist.map { $0.lowercased() })
        let blocklistLower = Set(blocklist.map { $0.lowercased() })
        let ruleKeys = Set(customRules.map { "\($0.source.lowercased())→\($0.target.lowercased())" })
        let dismissedSet = Set(dismissed)

        var undoneByWord: [String: Int] = [:]
        var undoneByBundle: [String: Int] = [:]
        var manualSwitchByPair: [String: (source: String, target: String, count: Int)] = [:]

        for entry in history {
            switch entry.kind {
            case .autoFixUndone:
                let key = entry.original.lowercased()
                undoneByWord[key, default: 0] += 1
                if let bundleID = entry.bundleID, !bundleID.isEmpty {
                    undoneByBundle[bundleID, default: 0] += 1
                }
            case .manualSwitch:
                guard !entry.originalTruncated, !entry.convertedTruncated else { continue }
                let src = entry.original.trimmingCharacters(in: .whitespacesAndNewlines)
                let tgt = entry.converted.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !src.isEmpty, !tgt.isEmpty else { continue }
                guard !src.contains(where: { $0.isWhitespace }) else { continue }
                guard !tgt.contains(where: { $0.isWhitespace }) else { continue }
                guard src.count >= 2, tgt.count >= 2 else { continue }
                let pairKey = "\(src.lowercased())→\(tgt.lowercased())"
                if var existing = manualSwitchByPair[pairKey] {
                    existing.count += 1
                    manualSwitchByPair[pairKey] = existing
                } else {
                    manualSwitchByPair[pairKey] = (src, tgt, 1)
                }
            case .autoFixApplied:
                break
            }
        }

        for (wordLower, count) in undoneByWord where count >= fibonacciThresholds.first! {
            if allowlistLower.contains(wordLower) { continue }
            let rec = Recommendation.addWordToAllowlist(
                word: wordLower,
                undoCount: count,
                tier: tier(for: count)
            )
            if dismissedSet.contains(rec.dedupKey) && count < fibonacciThresholds.last! { continue }
            recs.append(rec)
        }

        for (pairKey, info) in manualSwitchByPair where info.count >= fibonacciThresholds.first! {
            if ruleKeys.contains(pairKey) { continue }
            let rec = Recommendation.createCustomRule(
                source: info.source,
                target: info.target,
                count: info.count,
                tier: tier(for: info.count)
            )
            if dismissedSet.contains(rec.dedupKey) && info.count < fibonacciThresholds.last! { continue }
            recs.append(rec)
        }

        for (bundleID, count) in undoneByBundle where count >= minBlocklistThreshold {
            if blocklistLower.contains(bundleID.lowercased()) { continue }
            let rec = Recommendation.addAppToBlocklist(
                bundleID: bundleID,
                undoCount: count,
                tier: tier(for: count)
            )
            if dismissedSet.contains(rec.dedupKey) && count < fibonacciThresholds.last! { continue }
            recs.append(rec)
        }

        return recs.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
            return lhs.count > rhs.count
        }
    }
}
