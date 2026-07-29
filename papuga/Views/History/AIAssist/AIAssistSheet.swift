import AppKit
import Defaults
import SwiftUI

/// "Покращити з ШІ" — the bring-your-own-AI flow (AI-ASSIST.md §9), paste mode.
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
    @Default(.aiAnalysisTargets) private var analysisTargets

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
    @State private var providerRuns: [AIProvider: ProviderRunState] = [:]
    @State private var providerExecutions: [AIProvider: AIProviderBatchExecution] = [:]
    @State private var providerSuggestions: [AIProvider: [AISuggestion]] = [:]
    @State private var providerIssues: [AIProvider: String] = [:]
    @State private var runTasks: [AIProvider: Task<Void, Never>] = [:]
    @State private var comparisonPlan: AIComparisonBatchPlan?

    private enum Step { case intro, running, prompt, paste, review, done }
    private enum ProviderRunState {
        case running(AIProviderBatchProgress)
        case complete(AIProviderBatchProgress)
        case failed(AIProviderBatchProgress, String)
        case cancelled(AIProviderBatchProgress)
    }
    private enum ProviderRunError: LocalizedError {
        case notInstalled, needsAuthentication, failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "CLI не встановлено"
            case .needsAuthentication: return "Потрібна авторизація"
            case .failed(let message): return message
            }
        }
    }

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
                Text("Покращити з ШІ")
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
        case .running: return "Моделі аналізують паралельно"
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
        case .running: runningStep
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

            if analysisTargets.isEmpty {
                Label("AI targets не обрані. Manual copy/paste залишається доступним.", systemImage: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    ForEach(analysisTargets) { target in
                        Label(target.provider.title, systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(Color("BrandAccentDeep"))
                    }
                }
            }
        }
    }

    private var runningStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Кожна модель отримала ті самі локальні кандидати.")
                .font(.system(size: 13, weight: .medium))
            ForEach(analysisTargets) { target in
                HStack(spacing: 10) {
                    runStatusIcon(providerRuns[target.provider])
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.provider.title).font(.system(size: 13, weight: .semibold))
                        Text(runStatusText(providerRuns[target.provider]))
                            .font(.caption).foregroundStyle(.secondary)
                        if let progress = runProgress(providerRuns[target.provider]) {
                            ProgressView(value: progress.fractionCompleted)
                                .progressViewStyle(.linear)
                            Text("\(progress.completedItems) / \(progress.totalItems) · \(progress.resultCount) результатів · \(progress.missingCount) без відповіді")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Spacer()
                    if case .running? = providerRuns[target.provider] {
                        Button("Скасувати") { cancelProvider(target.provider) }
                            .buttonStyle(.borderless).foregroundStyle(.red)
                    } else if case .failed? = providerRuns[target.provider] {
                        Button("Повторити пакет") { retryProvider(target) }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
            Text("Помилка одного provider не скасовує готові результати інших.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func runStatusIcon(_ state: ProviderRunState?) -> some View {
        switch state {
        case .running, nil: ProgressView().controlSize(.small)
        case .complete: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color("BrandAccentDeep"))
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private func runStatusText(_ state: ProviderRunState?) -> String {
        switch state {
        case .running(let progress):
            return "Пакет \(min(progress.completedBatches + 1, progress.totalBatches)) з \(progress.totalBatches)"
        case .complete(let progress): return "Готово · \(progress.completedItems) оброблено"
        case .failed(let progress, let message):
            return "Пакет \(min(progress.completedBatches + 1, progress.totalBatches)) з \(progress.totalBatches): \(message)"
        case .cancelled(let progress): return "Скасовано після \(progress.completedItems)"
        case nil: return "Готується…"
        }
    }

    private func runProgress(_ state: ProviderRunState?) -> AIProviderBatchProgress? {
        switch state {
        case .running(let progress), .complete(let progress),
             .failed(let progress, _), .cancelled(let progress): return progress
        case nil: return nil
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
                Button("Manual prompt") { buildBatchAndAdvance() }
                    .buttonStyle(.bordered)
                Button("Порівняти \(analysisTargets.count) моделей") { startAnalysis() }
                    .buttonStyle(.borderedProminent).tint(Color("BrandAccentDeep"))
                    .disabled(analysisTargets.isEmpty || !consentGranted)
            case .running:
                Button("Назад") {
                    runTasks.values.forEach { $0.cancel() }
                    step = .intro
                }.buttonStyle(.bordered)
                Spacer()
                if providerRuns.values.allSatisfy({ state in
                    if case .running = state { return false }
                    return true
                }) {
                    Button("Порівняти готові") { finishComparison() }
                        .buttonStyle(.borderedProminent).tint(Color("BrandAccentDeep"))
                }
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
        batch = comparisonBatch()
        copied = false
        step = .prompt
    }

    private func comparisonBatch() -> AIPromptBatch {
        AIPromptBuilder.buildComparison(
            from: groups,
            candidatesBySource: comparisonCandidates(),
            sendAppNames: sendAppNames,
            scrubSecrets: secretScrubbing
        )
    }

    private func comparisonBatchPlan() -> AIComparisonBatchPlan {
        AIPromptBuilder.buildComparisonBatches(
            from: groups,
            candidatesBySource: comparisonCandidates(),
            sendAppNames: sendAppNames,
            scrubSecrets: secretScrubbing
        )
    }

    private func comparisonCandidates() -> [String: [MistakeSuggestionCandidate]] {
        var candidates: [String: [MistakeSuggestionCandidate]] = [:]
        for group in engineGroups {
            let key = MistakeObservation.normalizedToken(group.source)
            var seen = Set(candidates[key, default: []].map { MistakeObservation.normalizedToken($0.text) })
            for candidate in group.candidates where seen.insert(MistakeObservation.normalizedToken(candidate.text)).inserted {
                candidates[key, default: []].append(candidate)
            }
        }
        return candidates
    }

    private func startAnalysis() {
        let plan = comparisonBatchPlan()
        comparisonPlan = plan
        batch = plan.aggregateBatch
        guard plan.itemCount > 0 else { return }
        providerRuns = [:]
        providerExecutions = [:]
        providerSuggestions = [:]
        providerIssues = [:]
        runTasks.values.forEach { $0.cancel() }
        runTasks = [:]
        step = .running
        for target in analysisTargets {
            runProvider(target)
        }
    }

    private func runProvider(_ target: AIAnalysisTarget, resuming previous: AIProviderBatchExecution? = nil) {
        guard let plan = comparisonPlan else { return }
        let initial = previous ?? AIProviderBatchExecution(
            progress: AIProviderBatchProgress(totalItems: plan.itemCount, totalBatches: plan.batches.count),
            suggestions: [],
            failure: nil
        )
        providerRuns[target.provider] = .running(initial.progress)
        providerIssues.removeValue(forKey: target.provider)
        runTasks[target.provider]?.cancel()
        runTasks[target.provider] = Task {
            do {
                let execution = try await AIProviderBatchExecutor.run(
                    batches: plan.batches,
                    resuming: initial,
                    onProgress: { progress in
                        providerExecutions[target.provider] = progress
                        providerSuggestions[target.provider] = progress.suggestions
                        providerRuns[target.provider] = .running(progress.progress)
                    },
                    execute: { try await run(target, batch: $0) }
                )
                providerExecutions[target.provider] = execution
                providerSuggestions[target.provider] = execution.suggestions
                if let failure = execution.failure {
                    providerIssues[target.provider] = failure.message
                    providerRuns[target.provider] = .failed(execution.progress, failure.message)
                } else {
                    providerRuns[target.provider] = .complete(execution.progress)
                }
            } catch is CancellationError {
                let progress = providerExecutions[target.provider]?.progress ?? initial.progress
                providerRuns[target.provider] = .cancelled(progress)
            } catch {
                providerIssues[target.provider] = error.localizedDescription
                providerRuns[target.provider] = .failed(initial.progress, error.localizedDescription)
            }
        }
    }

    private func run(_ target: AIAnalysisTarget, batch: AIPromptBatch) async throws -> String {
        let prompt = batch.prompt
        let runner = AIAnalysisRunner()
        if target.provider == .ollama {
            let model: String?
            if let selected = target.model {
                model = selected
            } else {
                model = try await runner.discoverOllamaModels().first
            }
            guard let model else { throw AIAnalysisRunner.OllamaError.missingModel("Оберіть модель") }
            return try await runner.runOllama(model: model, prompt: prompt)
        }
        let state = await AIProviderDiscovery().probe(target)
        let executable: URL
        switch state {
        case .ready(let url, _): executable = url
        case .needsAuthentication: throw ProviderRunError.needsAuthentication
        case .notInstalled: throw ProviderRunError.notInstalled
        case .failed(let message): throw ProviderRunError.failed(message)
        }
        return try await runner.execute(
            executable: executable,
            arguments: target.provider.generationArguments,
            prompt: prompt
        ).stdout
    }

    private func cancelProvider(_ provider: AIProvider) {
        runTasks[provider]?.cancel()
        if let progress = providerExecutions[provider]?.progress ?? runProgress(providerRuns[provider]) {
            providerRuns[provider] = .cancelled(progress)
        }
    }

    private func retryProvider(_ target: AIAnalysisTarget) {
        guard let previous = providerExecutions[target.provider], previous.failure != nil else { return }
        runProvider(target, resuming: previous)
    }

    private func finishComparison() {
        guard let batch else { return }
        var byAlias: [String: [(AIProvider, AISuggestion)]] = [:]
        for (provider, suggestions) in providerSuggestions {
            for suggestion in suggestions { byAlias[suggestion.id, default: []].append((provider, suggestion)) }
        }
        let combined = byAlias.compactMap { alias, entries -> AISuggestion? in
            let grouped = Dictionary(grouping: entries) {
                MistakeObservation.normalizedToken($0.1.target ?? "")
            }
            guard let winner = grouped.max(by: { lhs, rhs in lhs.value.count < rhs.value.count })?.value,
                  let suggestion = winner.max(by: { $0.1.confidence < $1.1.confidence })?.1 else { return nil }
            let reasons = entries.map { "\($0.0.title): \($0.1.reason)" }.joined(separator: "\n")
            return AISuggestion(
                id: alias,
                action: .rule,
                target: suggestion.target,
                tag: suggestion.tag,
                clusterId: nil,
                confidence: suggestion.confidence,
                reason: "\(winner.count) з \(entries.count) погодились\n\(reasons)",
                needsReview: true
            )
        }
        guard !combined.isEmpty else {
            batch = comparisonBatch()
            result = AIValidationResult(blocked: AIValidationIssue(
                alias: nil, message: "Жоден provider не повернув придатний результат.", severity: .block
            ))
            step = .paste
            return
        }
        result = AIValidationResult(
            recognized: combined,
            issues: providerIssues.map { AIValidationIssue(alias: nil, message: "\($0.key.title): \($0.value)", severity: .warn) },
            missingAliases: batch.context.knownAliases.subtracting(Set(combined.map(\.id))).sorted()
        )
        editedAction = Dictionary(uniqueKeysWithValues: combined.map { ($0.id, $0.action) })
        editedTarget = Dictionary(uniqueKeysWithValues: combined.map { ($0.id, $0.target ?? "") })
        selected = []
        step = .review
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
        // Seed the per-row editable state from the AI's proposal.
        editedAction = Dictionary(uniqueKeysWithValues: r.recognized.map { ($0.id, $0.action) })
        editedTarget = Dictionary(uniqueKeysWithValues: r.recognized.map { ($0.id, $0.target ?? "") })

        selected = []
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
            Text("Немає рідкісних помилок для ШІ — усе вже опрацьовано або прибрано як секрети.")
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
