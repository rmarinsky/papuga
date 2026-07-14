import Foundation

/// One distinct word to classify, after merging the same mistake across apps. Carries every
/// observation it stands for, so applying a decision touches all of them (a rule is global).
struct AIPromptItem: Equatable {
    let source: String
    let language: String
    let observationIDs: [UUID]
    /// Kept locally only; the AI sees `source` (core), while apply-time safety
    /// can still detect punctuation-looking keys consumed by a layout mapping.
    let rawSources: [String]

    init(
        source: String,
        language: String,
        observationIDs: [UUID],
        rawSources: [String]? = nil
    ) {
        self.source = source
        self.language = language
        self.observationIDs = observationIDs
        self.rawSources = rawSources ?? [source]
    }

    func canCreateCoreRule(target: String, tag: AISuggestionTag) -> Bool {
        rawSources.allSatisfy {
            CoreRuleSafety.canCreateWithoutLayoutInterpretation(
                rawSource: $0,
                targetCore: target,
                isLayoutCandidate: tag == .layout
            )
        }
    }
}

/// Everything one round-trip needs: the prompt to hand to the user's AI, the validation
/// context the (already-built) `AIResponseValidator` consumes, the map from opaque alias
/// back to the real word for applying, and how many words were held back as secrets.
struct AIPromptBatch {
    let prompt: String
    let context: AIRoundTripContext
    /// alias ("m1"…) → the distinct word it stands for (merged across apps).
    let items: [String: AIPromptItem]
    let redactedSecretCount: Int
    /// True if more distinct words existed than `maxItems` and the rest were dropped this round.
    let truncatedBatch: Bool

    var itemCount: Int { items.count }
}

/// Serialises open mistakes into the alias-based prompt from AI-ASSIST.md §3.
///
/// Two things keep the prompt tight and honest:
///  • The same word typed in several apps is MERGED into one line — the model never sees, or
///    re-classifies, a duplicate. Applying the answer still resolves the word in every app.
///  • Only the opaque alias, the (optionally scrubbed) word, and a few human hints are sent —
///    never UUIDs, timestamps, or context hashes.
/// The strict JSON *output* contract (what `AIResponseValidator` parses) is unchanged; only the
/// human-readable input format differs. The worked example is load-bearing — without it a small
/// model conflates `target` with the tag name (proven against a real local qwen3:4b).
enum AIPromptBuilder {
    /// High enough to send everything in one batch (dedup keeps the real count well below this);
    /// only a pathological dataset would hit it, and then the leftover is reported, not dropped silently.
    static let defaultMaxItems = 1_500

    static func build(from groups: [MistakeGroupData],
                      sendAppNames: Bool,
                      scrubSecrets: Bool,
                      appNameForBundleID: ((String) -> String)? = nil,
                      maxItems: Int = defaultMaxItems) -> AIPromptBatch {
        // 1. Merge the same word (normalized source + language) across apps.
        var order: [String] = []
        var merged: [String: Merged] = [:]
        for group in groups {
            let sourceCore = BufferedToken.normalizedCore(from: group.source)
            let targetCore = group.target.map(BufferedToken.normalizedCore(from:))
            let key = MistakeObservation.normalizedToken(sourceCore) + "\u{1}" + group.language
            if var existing = merged[key] {
                existing.count += group.count
                existing.observationIDs.append(contentsOf: group.observationIDs)
                existing.rawSources.formUnion(group.entries.map(\.source))
                if existing.target == nil { existing.target = targetCore }
                if existing.truncated, !group.sourceTruncated {
                    existing.source = sourceCore
                    existing.truncated = false
                }
                if existing.issueType != .layoutCandidate, group.issueType == .layoutCandidate {
                    existing.issueType = .layoutCandidate
                }
                if let bundleID = group.bundleID { existing.appCounts[bundleID, default: 0] += group.count }
                merged[key] = existing
            } else {
                order.append(key)
                var appCounts: [String: Int] = [:]
                if let bundleID = group.bundleID { appCounts[bundleID] = group.count }
                merged[key] = Merged(
                    source: sourceCore,
                    language: group.language,
                    truncated: group.sourceTruncated,
                    count: group.count,
                    target: targetCore,
                    issueType: group.issueType,
                    observationIDs: group.observationIDs,
                    rawSources: Set(group.entries.map(\.source)),
                    appCounts: appCounts)
            }
        }

        // 2. Emit lines + validation context, scrubbing secrets and capping the batch.
        var lines: [String] = []
        var items: [String: AIPromptItem] = [:]
        var knownAliases: Set<String> = []
        var truncatedAliases: Set<String> = []
        var sourceForAlias: [String: String] = [:]
        var languageForAlias: [String: String] = [:]
        var redacted = 0
        var emitted = 0
        var consideredDistinct = 0

        for key in order {
            guard let item = merged[key] else { continue }
            if scrubSecrets, SecretScrubber.isLikelySecret(item.source) {
                redacted += 1
                continue
            }
            consideredDistinct += 1
            if emitted >= maxItems { continue }
            emitted += 1
            let alias = "m\(emitted)"

            items[alias] = AIPromptItem(
                source: item.source,
                language: item.language,
                observationIDs: item.observationIDs,
                rawSources: item.rawSources.sorted()
            )
            knownAliases.insert(alias)
            sourceForAlias[alias] = item.source
            languageForAlias[alias] = item.language
            if item.truncated { truncatedAliases.insert(alias) }

            lines.append(line(alias: alias, item: item, sendAppNames: sendAppNames, appNameForBundleID: appNameForBundleID))
        }

        let truncatedBatch = consideredDistinct > emitted
        let prompt = promptHeader + "\n" + lines.joined(separator: "\n")
        let context = AIRoundTripContext(
            knownAliases: knownAliases,
            truncatedAliases: truncatedAliases,
            sourceForAlias: sourceForAlias,
            languageForAlias: languageForAlias)

        return AIPromptBatch(prompt: prompt, context: context, items: items,
                             redactedSecretCount: redacted, truncatedBatch: truncatedBatch)
    }

    // MARK: - Line rendering (human-readable, one distinct word per line)

    private static func line(alias: String,
                             item: Merged,
                             sendAppNames: Bool,
                             appNameForBundleID: ((String) -> String)?) -> String {
        let shownSource = item.source + (item.truncated ? "…" : "")
        var line = "\(alias) «\(shownSource)»"
        if let target = item.target, !target.isEmpty {
            line += " → можливо «\(target)»"
        }
        line += " — \(item.count)×, мова \(item.language)"
        if sendAppNames, let appName = dominantAppName(item, appNameForBundleID: appNameForBundleID) {
            line += ", у \(appName)"
        }
        if item.issueType == .layoutCandidate {
            line += ", схоже на іншу розкладку"
        }
        return line
    }

    /// Clean human name of the app where this word is mistyped most — never a bundle-id code.
    private static func dominantAppName(_ item: Merged, appNameForBundleID: ((String) -> String)?) -> String? {
        guard let top = item.appCounts.max(by: { $0.value < $1.value })?.key else { return nil }
        let resolved = appNameForBundleID?(top) ?? top
        return looksLikeBundleID(resolved) ? nil : resolved
    }

    private static func looksLikeBundleID(_ name: String) -> Bool {
        name.contains(".") && name.split(separator: ".").count >= 3
    }

    static func kind(for issueType: MistakeObservation.IssueType) -> String {
        switch issueType {
        case .layoutCandidate: return "layout"
        case .spelling: return "spelling"
        case .manualCorrection: return "spelling"
        case .grammar: return "grammar"
        }
    }

    private struct Merged {
        var source: String
        var language: String
        var truncated: Bool
        var count: Int
        var target: String?
        var issueType: MistakeObservation.IssueType
        var observationIDs: [UUID]
        var rawSources: Set<String>
        var appCounts: [String: Int]
    }

    /// Human-readable instructions + worked example. The JSON output block is the strict
    /// contract `AIResponseValidator` parses.
    static let promptHeader = """
    Ти — класифікатор помилок введення українця-розробника.
    Нижче список слів, які я часто набираю неправильно. Для КОЖНОГО слова обери одну дію:

    • rule       — є одне правильне слово-заміна. target = саме правильне слово (НЕ назва категорії!).
    • dictionary — це справжнє слово, яке я вживаю свідомо (сленг, англіцизм, бренд: віджет, темплейт). target = null.
    • ignore     — шум, обрізок, випадковість. target = null.
    • merge      — кілька рядків — те саме слово; дай їм спільний clusterId і однакову target.

    Мітка tag — одне з: layout | spelling | domain | confusable | gibberish.

    Як відповідати: РІВНО один блок ```json і більше нічого. Усередині — масив із одним об'єктом на кожен id
    (ті самі id, що я дав). Поля об'єкта: id, action, target, tag, clusterId, confidence (0–1), reason.
    reason — коротке людське пояснення українською (одна фраза).

    Приклад (на інших словах):
    рядки —
      e1 «lkz» — 1×, мова uk
      e2 «дебажити» — 3×, мова uk
    відповідь —
    ```json
    {"version":1,"suggestions":[
    {"id":"e1","action":"rule","target":"для","tag":"layout","clusterId":null,"confidence":0.96,"reason":"набрано латиницею замість української розкладки"},
    {"id":"e2","action":"dictionary","target":null,"tag":"domain","clusterId":null,"confidence":0.9,"reason":"свідомий англіцизм, не помилка"}
    ]}```

    Мої слова:
    """
}
