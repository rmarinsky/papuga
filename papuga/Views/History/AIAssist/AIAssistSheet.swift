import AppKit
import Defaults
import SwiftUI

/// "Покращити з AI" — the bring-your-own-AI flow (AI-ASSIST.md §9), paste mode.
///
/// Steps: intro + consent → copy the generated prompt → paste the answer → validate
/// ("де не співпадає") → review + apply. The pasted answer is untrusted; it is only ever
/// run through `AIResponseValidator`, and nothing is applied until the user taps Застосувати.
struct AIAssistSheet: View {
    /// Open mistake groups to classify (carry source + observationIDs for applying).
    let groups: [MistakeGroupData]
    /// The engine's ranked suggestions, used only to corroborate AI rule targets.
    let engineGroups: [PredictionGroup]
    /// Enabled keyboard-layout source IDs, used to deterministically confirm layout flips.
    var layoutSourceIDs: [String] = []

    @Environment(\.dismiss) private var dismiss
    @Default(.aiConsentGranted) private var consentGranted
    @Default(.aiSecretScrubbing) private var secretScrubbing
    @Default(.aiSendAppNames) private var sendAppNames

    @State private var step: Step = .intro
    @State private var batch: AIPromptBatch?
    @State private var pasted = ""
    @State private var result: AIValidationResult?
    @State private var selected: Set<String> = []
    @State private var editedAction: [String: AISuggestionAction] = [:]
    @State private var editedTarget: [String: String] = [:]
    @State private var copied = false
    @State private var outcome: AISuggestionApplier.Outcome?
    @State private var applying = false
    @State private var applyProgress = 0
    @State private var applyTotal = 0

    private enum Step { case intro, prompt, paste, review, done }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color("BrandTintSoft"))
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("Покращити з AI")
                    .font(.system(size: 15, weight: .semibold))
                Text(stepTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Закрити")
        }
        .padding(16)
    }

    private var stepTitle: String {
        switch step {
        case .intro: return "Крок 1 з 4 — як це працює"
        case .prompt: return "Крок 2 з 4 — скопіювати промт"
        case .paste: return "Крок 3 з 4 — вставити відповідь"
        case .review: return "Крок 4 з 4 — переглянути й застосувати"
        case .done: return "Готово"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro: intro
        case .prompt: promptStep
        case .paste: pasteStep
        case .review: reviewStep
        case .done: doneStep
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            infoRow("1.circle", "Papuga складе промт із твоїх рідкісних помилок.")
            infoRow("doc.on.clipboard", "Копіюєш його у свій ChatGPT / Claude.")
            infoRow("arrow.down.doc", "Вставляєш відповідь назад — Papuga перевірить і застосує лише те, що ти підтвердиш.")

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Дозволяю надсилати слова моєму ШІ", isOn: $consentGranted)
                    .font(.system(size: 13, weight: .medium))
                Text("Застосунок не в пісочниці — цей перемикач єдине, що стримує слова від виходу з пристрою. Без нього промт не копіюється.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if secretScrubbing {
                    Label("Схожі на секрети слова прибираються автоматично.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(Color("BrandAccentDeep"))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color("BrandTintSoft").opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color("BrandAccentDeep").opacity(0.2), lineWidth: 1))
            )

            Text("Знайдено помилок для аналізу: \(groups.count)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var promptStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let batch, batch.itemCount > 0 {
                Text("Промт на \(batch.itemCount) \(pluralItems(batch.itemCount)) готовий.")
                    .font(.system(size: 13, weight: .medium))
                if batch.redactedSecretCount > 0 {
                    Label("\(batch.redactedSecretCount) слів прибрано як можливі секрети.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if batch.truncatedBatch {
                    Label("Показано найчастіші \(AIPromptBuilder.defaultMaxItems). Решту опрацюєш наступним разом.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(verbatim: batch.prompt)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 220)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
                )

                if !consentGranted {
                    Label("Увімкни дозвіл на кроці 1, щоб копіювати.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                emptyBatchNote
            }
        }
    }

    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Встав сюди всю відповідь від ШІ (разом із блоком ```json):")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Papuga прочитає JSON, звірить кожен пункт зі словами, які надсилала, і покаже, що збіглося, а що ні. Нічого не застосовується без твого підтвердження.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $pasted)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 220)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
                )
            if let result, result.isBlocked {
                AIValidationSummaryView(result: result)
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let result {
                AISuggestionReviewView(
                    recognized: result.recognized,
                    items: batch?.items ?? [:],
                    issues: result.issues,
                    selected: $selected,
                    editedAction: $editedAction,
                    editedTarget: $editedTarget
                )
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Застосовано", systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color("BrandAccentDeep"))
            if let outcome {
                summaryLine("Створено правил заміни", outcome.rulesCreated, "wand.and.stars")
                summaryLine("Додано в словник", outcome.addedToDictionary, "character.book.closed")
                summaryLine("Сховано", outcome.ignored, "eye.slash")
                if outcome.skippedStale > 0 {
                    summaryLine("Пропущено (вже опрацьовані)", outcome.skippedStale, "clock.arrow.circlepath")
                }
            }
        }
    }

    // MARK: - Footer (per-step actions)

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            switch step {
            case .intro:
                Spacer()
                Button("Скасувати") { dismiss() }.buttonStyle(.bordered)
                Button("Згенерувати промт") { buildBatchAndAdvance() }
                    .buttonStyle(.borderedProminent).tint(Color("BrandAccentDeep"))
            case .prompt:
                Button("Назад") { step = .intro }.buttonStyle(.bordered)
                Spacer()
                Button {
                    copyPrompt()
                } label: {
                    Label(copied ? "Скопійовано" : "Скопіювати промт", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(!consentGranted || (batch?.itemCount ?? 0) == 0)
                Button("Далі — вставити відповідь") { step = .paste }
                    .buttonStyle(.borderedProminent).tint(Color("BrandAccentDeep"))
                    .disabled((batch?.itemCount ?? 0) == 0)
            case .paste:
                Button("Назад") { step = .prompt }.buttonStyle(.bordered)
                Spacer()
                Button("Перевірити відповідь") { validate() }
                    .buttonStyle(.borderedProminent).tint(Color("BrandAccentDeep"))
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .review:
                if applying {
                    ProgressView().controlSize(.small)
                    Text("Застосовую… \(applyProgress)/\(applyTotal)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                } else {
                    Button("Назад") { step = .paste }.buttonStyle(.bordered)
                    Spacer()
                    Button("Застосувати (\(selected.count))") { applySelected() }
                        .buttonStyle(.borderedProminent).tint(Color("BrandAccentDeep"))
                        .disabled(selected.isEmpty)
                }
            case .done:
                Spacer()
                Button("Готово") { dismiss() }
                    .buttonStyle(.borderedProminent).tint(Color("BrandAccentDeep"))
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private func buildBatchAndAdvance() {
        batch = AIPromptBuilder.build(
            from: groups,
            sendAppNames: sendAppNames,
            scrubSecrets: secretScrubbing,
            appNameForBundleID: { AppContextProvider.displayName(forBundleID: $0) }
        )
        copied = false
        step = .prompt
    }

    private func copyPrompt() {
        guard consentGranted, let batch, batch.itemCount > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(batch.prompt, forType: .string)
        copied = true
    }

    private func validate() {
        guard let batch else { return }
        let r = AIResponseValidator.validate(pasted, context: batch.context, corroborate: corroborator())
        result = r
        guard !r.isBlocked else { return }
        // Default selection: confirmed rules ON; unconfirmed rules + dictionary + ignore OFF
        // (dictionary is irreversible — strictly opt-in, AI-ASSIST.md §7).
        // Seed the per-row editable state from the AI's proposal.
        editedAction = Dictionary(uniqueKeysWithValues: r.recognized.map { ($0.id, $0.action) })
        editedTarget = Dictionary(uniqueKeysWithValues: r.recognized.map { ($0.id, $0.target ?? "") })

        // Pre-select the safe set: dictionary (safe), plus corroborated rules — which now
        // includes deterministic layout flips, confirmed by the CharacterMapper corroborator.
        let preselected = r.recognized.filter { suggestion in
            if suggestion.action == .dictionary { return true }
            guard suggestion.action == .rule || suggestion.action == .merge else { return false }
            guard let target = suggestion.target, !target.isEmpty else { return false }
            return !suggestion.needsReview
        }
        selected = Set(preselected.map(\.id))
        step = .review
    }

    private func applySelected() {
        guard let batch, let result else { return }
        // Honour the per-row edits (changed action / edited replacement word).
        let chosen: [AISuggestion] = result.recognized
            .filter { selected.contains($0.id) }
            .map { suggestion in
                let action = editedAction[suggestion.id] ?? suggestion.action
                var target: String? = nil
                if action == .rule || action == .merge {
                    let edited = editedTarget[suggestion.id] ?? suggestion.target ?? ""
                    target = edited.isEmpty ? nil : edited
                }
                return AISuggestion(
                    id: suggestion.id, action: action, target: target, tag: suggestion.tag,
                    clusterId: suggestion.clusterId, confidence: suggestion.confidence,
                    reason: suggestion.reason, needsReview: suggestion.needsReview)
            }
        applying = true
        applyProgress = 0
        applyTotal = chosen.count
        Task { @MainActor in
            outcome = await AISuggestionApplier.applyAsync(
                chosen,
                items: batch.items,
                progress: { done, total in
                    applyProgress = done
                    applyTotal = total
                }
            )
            applying = false
            step = .done
        }
    }

    /// Confirms an AI rule target if the engine already proposed it or the user recorded it.
    private func corroborator() -> AIResponseValidator.TargetCorroborator {
        var candidatesBySource: [String: Set<String>] = [:]
        for group in engineGroups {
            let key = MistakeObservation.normalizedToken(group.source)
            var set = candidatesBySource[key] ?? []
            for candidate in group.candidates { set.insert(MistakeObservation.normalizedToken(candidate.text)) }
            if let primary = group.primaryTarget { set.insert(MistakeObservation.normalizedToken(primary)) }
            candidatesBySource[key] = set
        }
        var recordedBySource: [String: Set<String>] = [:]
        for group in groups {
            let key = MistakeObservation.normalizedToken(group.source)
            var set = recordedBySource[key] ?? []
            for target in group.recordedTargets { set.insert(MistakeObservation.normalizedToken(target)) }
            recordedBySource[key] = set
        }
        // Deterministic layout-flip check: the same keystrokes typed in another enabled layout.
        // This is exact (not a guess), so a confirmed flip is treated as safe (not needsReview).
        let mapper = CharacterMapper()
        let layouts = layoutSourceIDs
        return { source, target, _ in
            let key = MistakeObservation.normalizedToken(source)
            let tgt = MistakeObservation.normalizedToken(target)
            if candidatesBySource[key]?.contains(tgt) == true { return true }
            if recordedBySource[key]?.contains(tgt) == true { return true }
            for from in layouts {
                for to in layouts where to != from {
                    let mapped = mapper.convert(text: source, fromSourceID: from, toSourceID: to)
                    if MistakeObservation.normalizedToken(mapped) == tgt { return true }
                }
            }
            return false
        }
    }

    // MARK: - Small builders

    private func infoRow(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color("BrandAccentDeep"))
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func summaryLine(_ title: String, _ value: Int, _ systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.system(size: 13))
            Spacer()
            Text("\(value)").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }

    private var emptyBatchNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundStyle(.tertiary)
            Text("Немає рідкісних помилок для AI — усе вже опрацьовано або прибрано як секрети.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pluralItems(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "помилку" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "помилки" }
        return "помилок"
    }
}
