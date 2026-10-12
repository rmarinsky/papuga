import Carbon.HIToolbox
import Foundation

/// A bounded, local word-pair/bigram model rebuilt from retained history. Scores
/// influence ranking only: dictionary, protected-word and mutation gates still apply.
final class PersonalLayoutModel {
    static let shared = PersonalLayoutModel()

    private struct Key: Hashable {
        let original: String
        let candidate: String
        let sourceID: String
        let targetID: String
        let previousWord: String?
    }
    private var counts: [Key: Int] = [:]
    private var historyIDs: [UUID] = []
    private let mapper = CharacterMapper()

    func replaceHistory(_ history: [ReplacementHistoryEntry]) {
        let relevant = Array(history.filter { $0.kind == .manualSwitch || $0.kind == .autoFixUndone }
            .sorted { $0.timestamp > $1.timestamp }.prefix(2000))
        let ids = relevant.map(\.id)
        guard ids != historyIDs else { return }
        historyIDs = ids
        counts.removeAll()
        var lastEpisode: [Key: [String: Date]] = [:]
        // An undo invalidates earlier positive evidence for that exact source/result.
        var reversals: [String: Date] = [:]
        for entry in relevant where entry.kind == .autoFixUndone {
            let originals = entry.original.split(whereSeparator: \.isWhitespace)
            let candidates = entry.converted.split(whereSeparator: \.isWhitespace)
            guard originals.count == candidates.count else { continue }
            for (original, candidate) in zip(originals, candidates) {
                let key = reversalKey(String(original), String(candidate))
                reversals[key] = max(reversals[key] ?? .distantPast, entry.timestamp)
            }
        }
        for entry in relevant.reversed() where entry.kind == .manualSwitch {
            guard entry.verificationSucceeded == true,
                  !entry.originalTruncated, !entry.convertedTruncated,
                  entry.original != entry.converted,
                  let sourceID = entry.sourceLayoutID, let targetID = entry.targetLayoutID,
                  sourceID != targetID,
                  let source = inputSource(sourceID), let target = inputSource(targetID) else { continue }
            mapper.buildMap(for: source, sourceID: sourceID)
            mapper.buildMap(for: target, sourceID: targetID)
            guard mapper.hasMap(for: sourceID), mapper.hasMap(for: targetID),
                  mapper.convert(text: entry.original, fromSourceID: sourceID, toSourceID: targetID) == entry.converted
            else { continue }
            let originals = entry.original.split(whereSeparator: \.isWhitespace).map(String.init)
            let candidates = entry.converted.split(whereSeparator: \.isWhitespace).map(String.init)
            guard originals.count == candidates.count else { continue }
            // Old selections do not prove the last token was finished.
            let completedCount = originals.count - (entry.verificationSucceeded == true || entry.original.last?.isWhitespace == true ? 0 : 1)
            for index in 0..<max(0, completedCount) {
                let original = originals[index].lowercased(), candidate = candidates[index].lowercased()
                guard original.count >= 2, candidate.count >= 2,
                      original.allSatisfy(\.isLetter), candidate.allSatisfy(\.isLetter), original != candidate,
                      entry.timestamp > (reversals[reversalKey(original, candidate)] ?? .distantPast)
                else { continue }
                var keys = [Key(original: original, candidate: candidate, sourceID: sourceID,
                                targetID: targetID, previousWord: nil)]
                if index > 0 {
                    keys.append(Key(original: original, candidate: candidate, sourceID: sourceID,
                                    targetID: targetID, previousWord: originals[index - 1].lowercased()))
                }
                for key in keys {
                    let app = entry.bundleID ?? ""
                    if let previous = lastEpisode[key]?[app], entry.timestamp.timeIntervalSince(previous) < 60 { continue }
                    lastEpisode[key, default: [:]][app] = entry.timestamp
                    counts[key, default: 0] += entry.verificationSucceeded == true ? 2 : 1
                }
            }
        }
    }

    func boost(original: String, candidate: String, sourceID: String,
               targetID: String, previousWord: String? = nil) -> Double {
        let key = Key(original: original.lowercased(), candidate: candidate.lowercased(),
                      sourceID: sourceID, targetID: targetID, previousWord: nil)
        let count = counts[key] ?? 0
        guard count >= 3 else { return 0 }
        let contextual = Key(original: key.original, candidate: key.candidate, sourceID: sourceID,
                             targetID: targetID, previousWord: previousWord?.lowercased())
        let contextBonus = previousWord != nil && (counts[contextual] ?? 0) >= 3 ? 0.03 : 0
        return min(0.12, 0.02 * Double(count) + contextBonus)
    }

    private func reversalKey(_ original: String, _ candidate: String) -> String {
        original.lowercased() + "\u{0}" + candidate.lowercased()
    }

    private func inputSource(_ id: String) -> TISInputSource? {
        let query = [kTISPropertyInputSourceID!: id] as CFDictionary
        return (TISCreateInputSourceList(query, true)?.takeRetainedValue() as? [TISInputSource])?.first
    }
}
