import SwiftUI

/// "Помилки введення" — redesigned as a live prediction scanner.
///
/// The screen renders only from `PredictionEngine` snapshots: a progress header
/// while the background pass runs, a streaming feed of just-found (typo →
/// suggestion) pairs, and an accumulating list of the most frequent mistakes
/// ranked by frequency × confidence. It never computes spell-check work itself,
/// so it never freezes — even with tens of thousands of mistakes.
struct MistakesView: View {
    @Environment(LayoutManager.self) private var layoutManager

    @State private var engine = PredictionEngine.shared
    @State private var store = MistakeObservationStore.shared
    @State private var query = ""
    @State private var editorSeed: RuleEditorSeed?
    @State private var pendingObservationIDs: [UUID] = []
    @State private var showingClearConfirmation = false

    /// Only recurring mistakes with a usable suggestion are worth a rule.
    private let minOccurrences = 2
    private let minConfidence = 0.6

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if engine.phase == .analyzing {
                        AnalysisProgressBanner(
                            analyzed: engine.analyzedCount,
                            total: engine.totalCount,
                            liveFeed: engine.liveFeed
                        )
                    }
                    statsRow
                    suggestionsSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            engine.configure(layoutManager: layoutManager)
            engine.bootstrap()
        }
        .onChange(of: store.entries.count) {
            engine.noteNewObservations()
        }
        .sheet(item: $editorSeed) { seed in
            RuleEditorSheet(
                seed: seed,
                onClose: {
                    editorSeed = nil
                    pendingObservationIDs = []
                },
                onSave: { result in
                    markPending(result.mode == .replace ? .convertedToRule : .addedToDictionary)
                }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Spacer(minLength: 0)

            Button {
                engine.analyzeAll(force: true)
            } label: {
                Label("Переаналізувати все", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Перерахувати всі помилки заново")
            .disabled(engine.phase == .analyzing)

            searchField

            Button(role: .destructive) {
                showingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Очистити всі помилки")
            .disabled(store.entries.isEmpty)
            .confirmationDialog(
                "Очистити всі помилки введення?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Очистити", role: .destructive) { store.clearAll(); engine.analyzeAll(force: true) }
                Button("Скасувати", role: .cancel) {}
            } message: {
                Text("Цю дію не можна скасувати.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Пошук", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 140)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 10) {
            stat("Помилок", value: openCount, icon: "circle.fill")
            stat("Повторюваних", value: repeatedCount, icon: "repeat")
            stat("Правил", value: convertedCount, icon: "wand.and.stars")
            stat("Ігноровано", value: ignoredCount, icon: "hand.raised")
        }
    }

    private func stat(_ title: String, value: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color("BrandAccentDeep"))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
        )
    }

    // MARK: - Suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        let items = displayedSuggestions
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                Text("Найчастіші помилки")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if items.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider().opacity(0.45) }
                        PredictionCard(
                            group: group,
                            onCreateRule: { target in openRuleEditor(for: group, target: target) },
                            onIgnore: { addToDictionary(group) }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: items)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color("BrandAccentDeep").opacity(items.isEmpty ? 0.1 : 0.22), lineWidth: 1)
                )
        )
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: engine.phase == .analyzing ? "hourglass" : "checkmark.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(engine.phase == .analyzing
                 ? "Аналізую історію — поради з'являться тут…"
                 : (query.isEmpty
                    ? "Поки що немає повторюваних помилок для правила."
                    : "Нічого не знайдено."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Derived data

    private var displayedSuggestions: [PredictionGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return engine.ranked.filter { group in
            guard group.count >= minOccurrences else { return false }
            guard (group.candidates.first?.confidence ?? 0) >= minConfidence else { return false }
            guard group.primaryTarget != nil else { return false }
            guard !q.isEmpty else { return true }
            return group.source.localizedCaseInsensitiveContains(q)
                || (group.primaryTarget?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var openCount: Int { engine.flaggedCount }
    private var repeatedCount: Int { engine.ranked.lazy.filter { $0.count >= minOccurrences }.count }
    private var convertedCount: Int { store.entries.lazy.filter { $0.status == .convertedToRule }.count }
    private var ignoredCount: Int {
        store.entries.lazy.filter { $0.status == .dismissed || $0.status == .addedToDictionary }.count
    }

    // MARK: - Actions

    private func openRuleEditor(for group: PredictionGroup, target: String?) {
        pendingObservationIDs = group.observationIDs
        editorSeed = RuleEditorSeed(
            source: HistoryWordActionPolicy.normalizedSource(group.source),
            target: HistoryWordActionPolicy.sanitizedTarget(target ?? group.primaryTarget) ?? "",
            mode: .replace
        )
    }

    private func addToDictionary(_ group: PredictionGroup) {
        IgnoreWordService.add(group.source)
        store.updateStatus(forIDs: group.observationIDs, to: .addedToDictionary)
        engine.noteNewObservations()
    }

    private func markPending(_ status: MistakeObservation.Status) {
        store.updateStatus(forIDs: pendingObservationIDs, to: status)
        pendingObservationIDs = []
        engine.noteNewObservations()
    }
}

// MARK: - Live progress banner

private struct AnalysisProgressBanner: View {
    let analyzed: Int
    let total: Int
    let liveFeed: [FoundPair]

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(analyzed) / Double(total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("Аналізую помилки…")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(analyzed) / \(total)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            ProgressView(value: fraction)
                .tint(Color("BrandAccentDeep"))
                .animation(.easeInOut(duration: 0.25), value: fraction)

            if !liveFeed.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(liveFeed) { pair in
                        FoundPairChip(pair: pair)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.6).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: liveFeed)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color("BrandTintSoft").opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color("BrandAccentDeep").opacity(0.25), lineWidth: 1)
                )
        )
    }
}

private struct FoundPairChip: View {
    let pair: FoundPair

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: pair.kind.systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(pair.source)
                .strikethrough(color: .secondary)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color("BrandAccentDeep"))
            Text(pair.target)
                .foregroundStyle(Color("BrandAccentDeep"))
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
        )
    }
}

// MARK: - Ranked suggestion card

private struct PredictionCard: View {
    let group: PredictionGroup
    let onCreateRule: (String?) -> Void
    let onIgnore: () -> Void

    private var disabledReason: String? {
        HistoryWordActionPolicy.disabledReason(source: group.source, truncated: false)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconTile

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("\(group.count)×")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color("BrandAccentDeep"))
                        .monospacedDigit()
                    Text(group.language.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                    Text("остання: \(group.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                ReplacementReceipt(
                    source: group.source,
                    target: group.primaryTarget ?? "ввести заміну",
                    strikethroughSource: group.primaryTarget != nil
                )

                HistoryCandidateStrip(candidates: group.candidates) { candidate in
                    onCreateRule(candidate.text)
                }
            }

            Spacer(minLength: 12)

            HistoryRowActions(
                canAct: disabledReason == nil,
                disabledReason: disabledReason,
                onCreateRule: { onCreateRule(group.primaryTarget) },
                onIgnore: onIgnore
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color("BrandTintSoft"))
            Image(systemName: group.candidates.first?.kind.systemImage ?? "text.magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color("BrandAccentDeep"))
        }
        .frame(width: 32, height: 32)
    }
}
