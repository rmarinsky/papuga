import Foundation

/// Deterministically parses + validates an AI answer (pasted by the user, or returned by a local/
/// API model) against the strict contract in AI-ASSIST.md §4–5. The pasted text is UNTRUSTED:
/// we never execute anything, only read the closed schema keys, and every failure degrades safely.
enum AIResponseValidator {

    static let maxBytes = 2_000_000
    static let maxSuggestions = 3_000

    /// Optional independent corroborator for a `rule` target (e.g. a CharacterMapper layout-flip
    /// check, or "Papuga's own engine already proposed this target"). Returns true if the
    /// source -> target correction is plausible. When nil, only the pure default check is used.
    typealias TargetCorroborator = (_ source: String, _ target: String, _ language: String) -> Bool

    static func validate(_ rawText: String,
                         context: AIRoundTripContext,
                         corroborate: TargetCorroborator? = nil) -> AIValidationResult {
        var result = AIValidationResult()

        // --- size cap on untrusted input ---
        if rawText.utf8.count > maxBytes {
            result.blocked = AIValidationIssue(alias: nil,
                message: "Відповідь завелика (>256 КБ) — не парситься. Згенеруй промт меншим батчем.",
                severity: .block)
            return result
        }

        // --- extract + parse ---
        guard let jsonString = extractJSON(rawText) else {
            result.blocked = AIValidationIssue(alias: nil,
                message: "Не знайшов JSON. Скопіюй усю відповідь від ШІ повністю (разом із блоком ```json).",
                severity: .block)
            return result
        }
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any] else {
            result.blocked = AIValidationIssue(alias: nil,
                message: "Відповідь — не коректний JSON (можливо, обірвана). Попроси ШІ повторити одним блоком json.",
                severity: .block)
            return result
        }
        guard intValue(root["version"]) == 1, let rawSuggestions = root["suggestions"] as? [Any] else {
            result.blocked = AIValidationIssue(alias: nil,
                message: "Формат не той (нема version:1 чи масиву suggestions). Згенеруй промт ще раз.",
                severity: .block)
            return result
        }

        var suggestions = rawSuggestions
        var issues: [AIValidationIssue] = []
        if suggestions.count > maxSuggestions {
            issues.append(AIValidationIssue(alias: nil,
                message: "Понад \(maxSuggestions) пунктів — опрацьовую перші \(maxSuggestions).", severity: .warn))
            suggestions = Array(suggestions.prefix(maxSuggestions))
        }

        let requiredKeys = ["id", "action", "target", "tag", "clusterId", "confidence", "reason"]
        var accepted: [String: AISuggestion] = [:]
        var order: [String] = []
        var clusterCounts: [String: Int] = [:]

        for raw in suggestions {
            guard let item = raw as? [String: Any] else {
                issues.append(AIValidationIssue(alias: nil, message: "Пункт відповіді не об'єкт — пропущено.", severity: .warn))
                continue
            }
            guard let alias = item["id"] as? String, !alias.isEmpty else {
                issues.append(AIValidationIssue(alias: nil, message: "Пункт без поля id — пропущено.", severity: .warn))
                continue
            }
            let missing = requiredKeys.filter { !item.keys.contains($0) }
            if !missing.isEmpty {
                issues.append(AIValidationIssue(alias: alias,
                    message: "\(alias): бракує полів \(missing.sorted().joined(separator: ", ")) — пропущено.", severity: .warn))
                continue
            }
            guard context.knownAliases.contains(alias) else {
                issues.append(AIValidationIssue(alias: alias,
                    message: "\(alias): невідомий id — не було у списку цього раунду, пропущено.", severity: .warn))
                continue
            }
            if accepted[alias] != nil {
                issues.append(AIValidationIssue(alias: alias,
                    message: "\(alias): дубль — лишаю перший варіант.", severity: .warn))
                continue
            }
            guard let actionStr = item["action"] as? String, let action = AISuggestionAction(rawValue: actionStr) else {
                let shown = (item["action"] as? String).map { String($0.prefix(40)) } ?? "?"
                issues.append(AIValidationIssue(alias: alias,
                    message: "\(alias): невідома дія «\(shown)» — пропущено.", severity: .warn))
                continue
            }
            var tag = (item["tag"] as? String).flatMap(AISuggestionTag.init(rawValue:))
            if tag == nil {
                issues.append(AIValidationIssue(alias: alias,
                    message: "\(alias): невідома мітка — підставляю нейтральну.", severity: .info))
                tag = .spelling
            }
            var confidence = doubleValue(item["confidence"]) ?? 0.5
            confidence = min(1.0, max(0.0, confidence))

            let rawTarget = (item["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var finalTarget: String? = nil
            var needsReview = false
            let impliesRule = action == .rule || (action == .merge && rawTarget != nil)

            if impliesRule {
                guard let target = rawTarget else {
                    issues.append(AIValidationIssue(alias: alias,
                        message: "\(alias): немає заміни — AI не дав target. Правило не створюю.", severity: .warn))
                    continue
                }
                if context.truncatedAliases.contains(alias) {
                    issues.append(AIValidationIssue(alias: alias,
                        message: "\(alias): слово обрізане («…») — не будую правило з обрізаного слова.", severity: .warn))
                    continue
                }
                let source = context.sourceForAlias[alias] ?? ""
                if source.caseInsensitiveCompare(target) == .orderedSame {
                    issues.append(AIValidationIssue(alias: alias,
                        message: "\(alias): правило замінює слово на себе — пропущено.", severity: .warn))
                    continue
                }
                let language = context.languageForAlias[alias] ?? "uk"
                let plausible = (corroborate?(source, target, language) ?? false)
                    || defaultTargetPlausible(source: source, target: target, language: language)
                if !plausible {
                    needsReview = true
                    issues.append(AIValidationIssue(alias: alias,
                        message: "\(alias): заміну не підтверджено незалежно — на перевірку перед застосуванням.", severity: .info))
                }
                finalTarget = target
            } else if rawTarget != nil {
                // dictionary/ignore must not carry a target
                issues.append(AIValidationIssue(alias: alias,
                    message: "\(alias): target там, де не треба (\(action.rawValue)) — заміну відкидаю, дію лишаю.", severity: .info))
            }

            let reason = (item["reason"] as? String).map { String($0.prefix(120)) } ?? ""
            let clusterId = (item["clusterId"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            accepted[alias] = AISuggestion(id: alias, action: action, target: finalTarget,
                                           tag: tag!, clusterId: clusterId, confidence: confidence,
                                           reason: reason, needsReview: needsReview)
            order.append(alias)
            if let cid = clusterId { clusterCounts[cid, default: 0] += 1 }
        }

        // cluster hygiene: a cluster needs >= 2 members
        for (cid, n) in clusterCounts where n < 2 {
            issues.append(AIValidationIssue(alias: nil,
                message: "Група злиття «\(cid)» з одного пункта — показую як звичайну пораду.", severity: .info))
        }

        let recognized = order.compactMap { accepted[$0] }
        if recognized.isEmpty {
            result.blocked = AIValidationIssue(alias: nil,
                message: "Жодного відомого пункта — схоже, це чужа/стара відповідь або вставлено не те.",
                severity: .block)
            return result
        }

        let answered = Set(accepted.keys)
        let missing = context.knownAliases.subtracting(answered).sorted()
        if !missing.isEmpty {
            issues.append(AIValidationIssue(alias: nil,
                message: "ШІ не опрацював \(missing.count) — можна догенерувати промт лише для них.", severity: .info))
        }

        result.recognized = recognized
        result.issues = issues
        result.missingAliases = missing
        return result
    }

    // MARK: - JSON extraction (fence-strip -> brace-scan fallback)

    static func extractJSON(_ text: String) -> String? {
        if let fenceStart = text.range(of: "```") {
            let rest = text[fenceStart.upperBound...]
            if let fenceEnd = rest.range(of: "```") {
                var inner = String(rest[..<fenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.lowercased().hasPrefix("json") { inner = String(inner.dropFirst(4)) }
                inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.first == "{" { return inner }
            }
        }
        if let i = text.firstIndex(of: "{"), let j = text.lastIndex(of: "}"), i < j {
            return String(text[i...j])
        }
        return nil
    }

    // MARK: - Target plausibility (pure default; layout flips need an injected corroborator)

    static func defaultTargetPlausible(source: String, target: String, language: String) -> Bool {
        let s = source.lowercased(), t = target.lowercased()
        guard !s.isEmpty, !t.isEmpty else { return false }
        // same-script ordinary typo within a small edit distance
        if dominantScript(s) == dominantScript(t), dominantScript(t) != .other {
            let bound = max(2, t.count / 3)
            if osaDistance(s, t) <= bound { return true }
        }
        return false
    }

    enum Script { case latin, cyrillic, other }

    static func dominantScript(_ s: String) -> Script {
        var latin = 0, cyr = 0
        for ch in s.unicodeScalars {
            if ("a"..."z").contains(Character(ch)) || ("A"..."Z").contains(Character(ch)) { latin += 1 }
            else if (0x0400...0x04FF).contains(ch.value) { cyr += 1 }
        }
        if cyr == 0 && latin == 0 { return .other }
        return cyr >= latin ? .cyrillic : .latin
    }

    // MARK: - helpers

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// Optimal String Alignment (Damerau-Levenshtein with adjacent transpositions).
    static func osaDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        let n = x.count, m = y.count
        if n == 0 { return m }
        if m == 0 { return n }
        var prev2 = [Int](repeating: 0, count: m + 1)
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    cur[j] = min(cur[j], prev2[j - 2] + 1)
                }
            }
            prev2 = prev; prev = cur; cur = [Int](repeating: 0, count: m + 1)
        }
        return prev[m]
    }
}
