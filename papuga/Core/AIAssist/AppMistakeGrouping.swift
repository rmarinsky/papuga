import Foundation

/// One application's worth of ranked mistake suggestions.
///
/// `PredictionEngine` deliberately merges suggestions across apps ("a rule is global,
/// so one 'кщьфт → roman 6×' beats two '3×' cards"), so by the time we hold
/// `[PredictionGroup]` the bundleID axis is gone. `AppMistakeGrouping` re-introduces it
/// WITHOUT touching the engine: each already-ranked, quality-filtered group is split into
/// per-app rows by the bundleID recorded on its underlying observations. The engine's
/// confidence/candidate filtering is preserved; we only regroup what survived it.
struct AppMistakeGroup: Identifiable, Equatable {
    /// `nil` when the originating app could not be determined.
    let bundleID: String?
    /// Per-app suggestion rows, sorted strongest-first.
    let rows: [PredictionGroup]

    var id: String { bundleID ?? AppMistakeGrouping.unknownKey }
    var totalCount: Int { rows.reduce(0) { $0 + $1.count } }
}

enum AppMistakeGrouping {
    static let unknownKey = "__unknown_app__"

    /// Split `groups` into per-app rows and bucket them by app, apps ordered by total volume.
    /// - Parameters:
    ///   - groups: the engine's ranked, quality-filtered suggestions (e.g. `displayedSuggestions`).
    ///   - observations: the full observation set, used to recover each observation's bundleID.
    static func appGroups(from groups: [PredictionGroup],
                          observations: [MistakeObservation]) -> [AppMistakeGroup] {
        guard !groups.isEmpty else { return [] }

        var bundleByID: [UUID: String?] = [:]
        var timestampByID: [UUID: Date] = [:]
        bundleByID.reserveCapacity(observations.count)
        timestampByID.reserveCapacity(observations.count)
        for obs in observations {
            bundleByID[obs.id] = obs.bundleID
            timestampByID[obs.id] = obs.timestamp
        }

        var rowsByKey: [String: [PredictionGroup]] = [:]
        var bundleForKey: [String: String?] = [:]

        for group in groups {
            var idsByKey: [String: [UUID]] = [:]
            var lastSeenByKey: [String: Date] = [:]
            for oid in group.observationIDs {
                let bundle = bundleByID[oid] ?? nil
                let key = bundle ?? unknownKey
                idsByKey[key, default: []].append(oid)
                bundleForKey[key] = bundle
                if let ts = timestampByID[oid] {
                    lastSeenByKey[key] = max(lastSeenByKey[key] ?? .distantPast, ts)
                }
            }
            // A ranked group whose observations we cannot resolve still surfaces, intact.
            if idsByKey.isEmpty {
                idsByKey[unknownKey] = group.observationIDs
                bundleForKey[unknownKey] = nil
            }
            for (key, ids) in idsByKey {
                let row = PredictionGroup(
                    id: group.id + "::" + key,
                    source: group.source,
                    language: group.language,
                    count: ids.count,
                    lastSeen: lastSeenByKey[key] ?? group.lastSeen,
                    candidates: group.candidates,
                    primaryTarget: group.primaryTarget,
                    observationIDs: ids
                )
                rowsByKey[key, default: []].append(row)
            }
        }

        return rowsByKey
            .map { key, rows in
                AppMistakeGroup(
                    bundleID: bundleForKey[key] ?? nil,
                    rows: rows.sorted { lhs, rhs in
                        if lhs.score != rhs.score { return lhs.score > rhs.score }
                        return lhs.count > rhs.count
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalCount != rhs.totalCount { return lhs.totalCount > rhs.totalCount }
                // Deterministic tiebreak with no AppKit dependency; the unknown bucket sinks last.
                let l = lhs.bundleID ?? "\u{10FFFF}"
                let r = rhs.bundleID ?? "\u{10FFFF}"
                return l < r
            }
    }
}
