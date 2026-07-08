import AppKit
import Defaults
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
    @State private var mode: Mode = .suggestions
    @State private var editorSeed: RuleEditorSeed?
    @State private var pendingObservationIDs: [UUID] = []
    @State private var showingClearConfirmation = false
    @State private var showingAIAssist = false
    @State private var displayCache = AppDisplayCache()
    /// Normalized sources optimistically removed from the list the instant the user saves them
    /// to the dictionary, so the click feels immediate while the slow spell-checker work defers.
    @State private var dismissedSources: Set<String> = []
    @Default(.mistakesGroupingMode) private var groupingRaw
    @State private var collapsedGroupIDs: Set<String> = []

    private var groupingMode: MistakesGroupingMode { MistakesGroupingMode(rawValue: groupingRaw) ?? .byApp }

    private enum Mode: String, CaseIterable, Identifiable {
        case suggestions, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .suggestions: return "Поради"
            case .all: return "Усі помилки"
            }
        }
    }

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
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch mode {
                    case .suggestions: suggestionsSection
                    case .all: allErrorsSection
                    }
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
        .sheet(isPresented: $showingAIAssist) {
            AIAssistSheet(
                groups: MistakesScreenDerivation.groups(from: store.entries, filter: .all, query: ""),
                engineGroups: displayedSuggestions,
                layoutSourceIDs: layoutManager.orderedLayouts()
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Spacer(minLength: 0)

            Button {
                showingAIAssist = true
            } label: {
                Label("Покращити з ШІ", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color("BrandAccentDeep"))
            .help("Класифікувати рідкісні помилки за допомогою свого ШІ")
            .disabled(store.entries.isEmpty)

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
            stat("Правил заміни", value: convertedCount, icon: "wand.and.stars")
            stat("Збережено в словник", value: ignoredCount, icon: "character.book.closed")
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
        let appGroups = displayedAppGroups
        let total = appGroups.reduce(0) { $0 + $1.rows.count }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                Text("Найчастіші помилки — по застосунках")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if total > 0 {
                    Text("\(total)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if appGroups.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(appGroups) { appGroup in
                        appSection(appGroup)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity
                            ))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: appGroups)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color("BrandAccentDeep").opacity(appGroups.isEmpty ? 0.1 : 0.22), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func appSection(_ appGroup: AppMistakeGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AppGroupHeader(
                name: displayCache.name(for: appGroup.bundleID),
                icon: displayCache.icon(for: appGroup.bundleID),
                count: appGroup.totalCount
            )
            ForEach(Array(appGroup.rows.enumerated()), id: \.element.id) { index, group in
                if index > 0 { Divider().opacity(0.45) }
                PredictionCard(
                    group: group,
                    onCreateRule: { target in openRuleEditor(for: group, target: target) },
                    onIgnore: { addToDictionary(group) }
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    // MARK: - All errors browser (switchable grouping format — design 634:2)

    /// Every open mistake, query-filtered and minus words just sent to the dictionary.
    private var openMistakeGroups: [MistakeGroupData] {
        MistakesScreenDerivation.groups(from: store.entries, filter: .all, query: query)
            .filter { !dismissedSources.contains(MistakeObservation.normalizedToken($0.source)) }
    }

    @ViewBuilder
    private var allErrorsSection: some View {
        let groups = openMistakeGroups
        VStack(alignment: .leading, spacing: 12) {
            switch groupingMode {
            case .byApp:
                let buckets = appBuckets(groups)
                groupingBar(groupIDs: buckets.map(\.id))
                byAppBrowser(buckets)
            case .inbox:
                groupingBar(groupIDs: [])
                inboxBrowser(groups)
            case .families:
                let clusters = displayedClusters
                groupingBar(groupIDs: clusters.map(\.id))
                familiesBrowser(clusters)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func groupingBar(groupIDs: [String]) -> some View {
        HStack(spacing: 10) {
            Text("ГРУПУВАТИ")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Menu {
                ForEach(MistakesGroupingMode.allCases) { mode in
                    Button {
                        groupingRaw = mode.rawValue
                    } label: {
                        Label(mode.title, systemImage: mode.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(groupingMode.title).font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            if !groupIDs.isEmpty {
                Button("Розгорнути все") { collapsedGroupIDs.subtract(groupIDs) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color("BrandAccentDeep"))
                Button("Згорнути все") { collapsedGroupIDs.formUnion(groupIDs) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: за застосунком

    private struct AppBucket: Identifiable {
        let bundleID: String?
        let groups: [MistakeGroupData]
        var id: String { bundleID ?? AppMistakeGrouping.unknownKey }
        var totalCount: Int { groups.reduce(0) { $0 + $1.count } }
    }

    private func appBuckets(_ groups: [MistakeGroupData]) -> [AppBucket] {
        var byKey: [String: [MistakeGroupData]] = [:]
        var bundleForKey: [String: String?] = [:]
        for group in groups {
            let key = group.bundleID ?? AppMistakeGrouping.unknownKey
            byKey[key, default: []].append(group)
            bundleForKey[key] = group.bundleID
        }
        return byKey
            .map { key, value in AppBucket(bundleID: bundleForKey[key] ?? nil, groups: value) }
            .sorted { lhs, rhs in
                if lhs.totalCount != rhs.totalCount { return lhs.totalCount > rhs.totalCount }
                return (lhs.bundleID ?? "\u{10FFFF}") < (rhs.bundleID ?? "\u{10FFFF}")
            }
    }

    @ViewBuilder
    private func byAppBrowser(_ buckets: [AppBucket]) -> some View {
        if buckets.isEmpty {
            emptyState
        } else {
            proportionBar(buckets)
            if let top = topAppsCaption(buckets) {
                Text(top).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 10) {
                ForEach(buckets) { bucket in
                    appBucketSection(bucket)
                }
            }
        }
    }

    @ViewBuilder
    private func appBucketSection(_ bucket: AppBucket) -> some View {
        let collapsed = collapsedGroupIDs.contains(bucket.id)
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                appIconTile(bucket.bundleID)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayCache.name(for: bucket.bundleID))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(bucket.groups.count) видно")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Text("\(bucket.totalCount)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .monospacedDigit()
                Button("Усі в словник") { addWordsToDictionary(bucket.groups.map(\.source)) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color("BrandTintSoft").opacity(0.4))
            .contentShape(Rectangle())
            .onTapGesture { toggleCollapsed(bucket.id) }

            if !collapsed {
                ForEach(Array(bucket.groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider().opacity(0.4) }
                    MistakeBrowserRow(
                        group: group,
                        ruleDisabledReason: browserRuleDisabledReason(for: group),
                        onCreateRule: { openRuleEditor(for: group) },
                        onDictionary: { addWordsToDictionary([group.source]) }
                    )
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func proportionBar(_ buckets: [AppBucket]) -> some View {
        let shown = Array(buckets.prefix(8))
        let total = max(1, shown.reduce(0) { $0 + $1.totalCount })
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, bucket in
                    let fraction = CGFloat(bucket.totalCount) / CGFloat(total)
                    segmentColor(index)
                        .frame(width: max(10, geo.size.width * fraction - 2))
                        .overlay(alignment: .leading) {
                            if fraction > 0.14 {
                                Text("\(displayCache.name(for: bucket.bundleID)) \(bucket.totalCount)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .padding(.leading, 8)
                            }
                        }
                }
            }
        }
        .frame(height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func topAppsCaption(_ buckets: [AppBucket]) -> String? {
        let named = buckets.prefix(2).map { displayCache.name(for: $0.bundleID) }
        guard !named.isEmpty else { return nil }
        return "Найбільше помилок там, де ти найбільше друкуєш — у \(named.joined(separator: " та "))."
    }

    private func segmentColor(_ index: Int) -> Color {
        let palette: [Color] = [
            Color("BrandAccentDeep"), Color("BrandAccent"), .teal, .orange,
            .blue, .brown, .gray, .indigo,
        ]
        return palette[index % palette.count]
    }

    @ViewBuilder
    private func appIconTile(_ bundleID: String?) -> some View {
        if let icon = displayCache.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary)
                Image(systemName: "app.dashed").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 18, height: 18)
        }
    }

    // MARK: інбокс

    @ViewBuilder
    private func inboxBrowser(_ groups: [MistakeGroupData]) -> some View {
        if groups.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider().opacity(0.4) }
                    MistakeBrowserRow(
                        group: group,
                        ruleDisabledReason: browserRuleDisabledReason(for: group),
                        onCreateRule: { openRuleEditor(for: group) },
                        onDictionary: { addWordsToDictionary([group.source]) }
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
        }
    }

    // MARK: родини

    @ViewBuilder
    private func familiesBrowser(_ clusters: [ErrorCluster]) -> some View {
        let multi = clusters.filter { !$0.isSingleton }
        let singles = clusters.filter(\.isSingleton).flatMap(\.members)
        if clusters.isEmpty {
            emptyState
        } else {
            if !multi.isEmpty {
                Text("Схожі між собою")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                LazyVStack(spacing: 0) {
                    ForEach(Array(multi.enumerated()), id: \.element.id) { index, cluster in
                        if index > 0 { Divider().opacity(0.4) }
                        ClusterCard(cluster: cluster) { member in openRuleEditor(for: member) }
                    }
                }
            }
            if !singles.isEmpty {
                Text("Поодинокі")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                    .padding(.top, multi.isEmpty ? 0 : 6)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(singles) { member in
                        ErrorChip(member: member) { openRuleEditor(for: member) }
                    }
                }
            }
        }
    }

    private func toggleCollapsed(_ id: String) {
        if collapsedGroupIDs.contains(id) { collapsedGroupIDs.remove(id) } else { collapsedGroupIDs.insert(id) }
    }

    private var displayedClusters: [ErrorCluster] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return engine.errorClusters }
        return engine.errorClusters.compactMap { cluster in
            let members = cluster.members.filter {
                $0.source.localizedCaseInsensitiveContains(q)
                    || ($0.target?.localizedCaseInsensitiveContains(q) ?? false)
            }
            guard !members.isEmpty else { return nil }
            return ErrorCluster(id: cluster.id, representative: cluster.representative,
                                language: cluster.language, members: members)
        }
    }

    private func openRuleEditor(for member: ErrorClusterMember) {
        guard member.isCoreRuleCreationAllowed else { return }
        pendingObservationIDs = member.observationIDs
        editorSeed = RuleEditorSeed(
            source: HistoryWordActionPolicy.normalizedSource(member.source),
            target: HistoryWordActionPolicy.sanitizedTarget(member.target) ?? "",
            mode: .replace
        )
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

    /// The same quality-filtered suggestions, regrouped under the app they came from.
    private var displayedAppGroups: [AppMistakeGroup] {
        let groups = AppMistakeGrouping.appGroups(from: displayedSuggestions, observations: store.entries)
        guard !dismissedSources.isEmpty else { return groups }
        return groups.compactMap { appGroup in
            let rows = appGroup.rows.filter {
                !dismissedSources.contains(MistakeObservation.normalizedToken($0.source))
            }
            return rows.isEmpty ? nil : AppMistakeGroup(bundleID: appGroup.bundleID, rows: rows)
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
        let resolvedTarget = target ?? group.primaryTarget
        let targetCandidate = resolvedTarget.flatMap { target in
            group.candidates.first {
                MistakeObservation.normalizedToken($0.text)
                    == MistakeObservation.normalizedToken(target)
            }
        }
        guard targetCandidate?.canCreateCoreRule != false else { return }
        pendingObservationIDs = group.observationIDs
        editorSeed = RuleEditorSeed(
            source: HistoryWordActionPolicy.normalizedSource(group.source),
            target: HistoryWordActionPolicy.sanitizedTarget(resolvedTarget) ?? "",
            mode: .replace
        )
    }

    private func openRuleEditor(for group: MistakeGroupData) {
        guard browserRuleDisabledReason(for: group) == nil else { return }
        pendingObservationIDs = group.observationIDs
        editorSeed = RuleEditorSeed(
            source: HistoryWordActionPolicy.normalizedSource(group.source),
            target: HistoryWordActionPolicy.sanitizedTarget(group.target) ?? "",
            mode: .replace
        )
    }

    private func ruleCandidate(for group: MistakeGroupData) -> MistakeSuggestionCandidate? {
        let normalizedSource = MistakeObservation.normalizedToken(group.source)
        guard let target = group.target else { return nil }
        for prediction in engine.ranked where
            MistakeObservation.normalizedToken(prediction.source) == normalizedSource
                && prediction.language == group.language {
            if let candidate = prediction.candidates.first(where: {
                MistakeObservation.normalizedToken($0.text)
                    == MistakeObservation.normalizedToken(target)
                    && $0.replacementPlan?.rawSource == group.source
            }) {
                return candidate
            }
        }
        return nil
    }

    private func browserRuleDisabledReason(for group: MistakeGroupData) -> String? {
        let token = BufferedToken(rawText: group.source, keyCodes: [])
        guard !token.leadingEdge.isEmpty || !token.trailingEdge.isEmpty else { return nil }
        guard let candidate = ruleCandidate(for: group) else {
            return HistoryWordActionPolicy.unverifiedEdgeRuleReason
        }
        return HistoryWordActionPolicy.ruleDisabledReason(for: candidate)
    }

    /// Save one or many words to the dictionary at once (single row or a whole app's «Усі в словник»).
    /// Same optimistic-removal + deferred-heavy-work shape as `addToDictionary`.
    private func addWordsToDictionary(_ sources: [String]) {
        let keys = Set(sources.map(MistakeObservation.normalizedToken)).filter { !$0.isEmpty }
        guard !keys.isEmpty else { return }
        dismissedSources.formUnion(keys)
        Task { @MainActor in
            for source in sources { IgnoreWordService.add(source) }
            let ids = store.entries
                .filter { $0.status == .open && keys.contains($0.normalizedSource) }
                .map(\.id)
            store.updateStatus(forIDs: ids, to: .addedToDictionary)
            engine.noteNewObservations()
        }
    }

    private func addToDictionary(_ group: PredictionGroup) {
        let key = MistakeObservation.normalizedToken(group.source)
        // Optimistic: drop every row for this word right away so the click is instant. The
        // expensive part (NSSpellChecker.learnWord IPC + re-analysis) then runs off the click.
        dismissedSources.insert(key)
        Task { @MainActor in
            IgnoreWordService.add(group.source)
            // A dictionary entry is global — resolve this word across ALL apps, not just the
            // tapped row's observations.
            let ids = store.entries
                .filter { $0.status == .open && $0.normalizedSource == key }
                .map(\.id)
            store.updateStatus(forIDs: ids, to: .addedToDictionary)
            engine.noteNewObservations()
        }
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
            Text(pair.renderedTarget)
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

    private var primaryCandidate: MistakeSuggestionCandidate? {
        group.primaryTarget.flatMap { target in
            group.candidates.first {
                MistakeObservation.normalizedToken($0.text)
                    == MistakeObservation.normalizedToken(target)
            }
        }
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
                    target: group.renderedPrimaryTarget ?? "ввести заміну",
                    strikethroughSource: group.primaryTarget != nil
                )

                HistoryCandidateStrip(candidates: group.candidates) { candidate in
                    guard candidate.canCreateCoreRule else { return }
                    onCreateRule(candidate.text)
                }
            }

            Spacer(minLength: 12)

            HistoryRowActions(
                canAct: disabledReason == nil,
                disabledReason: disabledReason,
                ruleDisabledReason: HistoryWordActionPolicy.ruleDisabledReason(for: primaryCandidate),
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

// MARK: - All-errors cluster views

private struct ClusterCard: View {
    let cluster: ErrorCluster
    let onSelectMember: (ErrorClusterMember) -> Void

    private var sharedTarget: String? {
        guard !cluster.members.contains(where: {
            MistakeObservation.normalizedToken($0.source)
                == MistakeObservation.normalizedToken(cluster.representative)
        }) else { return nil }
        return cluster.representative
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color("BrandTintSoft"))
                Image(systemName: "circle.grid.cross")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color("BrandAccentDeep"))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("\(cluster.members.count) схожих")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(cluster.language.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                    if let sharedTarget {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold))
                            Text(sharedTarget).font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color("BrandAccentDeep"))
                    }
                }
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(cluster.members) { member in
                        ErrorChip(member: member, showTarget: sharedTarget == nil) {
                            onSelectMember(member)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ErrorChip: View {
    let member: ErrorClusterMember
    var showTarget: Bool = true
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(member.source)
                    .strikethrough(showTarget && member.target != nil, color: .secondary)
                    .foregroundStyle(showTarget && member.target != nil ? .secondary : .primary)
                if showTarget, let target = member.target {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color("BrandAccentDeep"))
                    Text(target).foregroundStyle(Color("BrandAccentDeep"))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                    .overlay(Capsule(style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .disabled(!member.isCoreRuleCreationAllowed)
        .help(!member.isCoreRuleCreationAllowed
            ? HistoryWordActionPolicy.fullTokenLayoutRuleReason
            : "Створити правило заміни для «\(member.source)»")
    }
}

// MARK: - Compact browser row ("Усі помилки")

private struct MistakeBrowserRow: View {
    let group: MistakeGroupData
    let ruleDisabledReason: String?
    let onCreateRule: () -> Void
    let onDictionary: () -> Void

    private var hasTarget: Bool {
        if let target = group.target { return !target.isEmpty }
        return false
    }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(hasTarget ? Color("BrandAccentDeep") : .orange)
                .frame(width: 7, height: 7)

            if hasTarget, let target = group.renderedTarget {
                Text(group.source)
                    .font(.system(size: 12, design: .monospaced))
                    .strikethrough(color: .secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Color("BrandAccentDeep"))
                Text(target)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .lineLimit(1)
            } else {
                Text(group.source)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Text(group.language.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            if group.count > 1 {
                Text("×\(group.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .monospacedDigit()
            }
            Text(relativeTime(group.lastSeen))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(action: onDictionary) { Image(systemName: "character.book.closed") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Зберегти в словник")
            if hasTarget {
                Button(action: onCreateRule) { Image(systemName: "wand.and.stars") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .disabled(ruleDisabledReason != nil)
                    .help(ruleDisabledReason ?? "Створити правило заміни")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relativeTime(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        switch days {
        case ..<1: return "сьогодні"
        case 1: return "вчора"
        case 2...6: return "\(days) дн."
        default: return "\(days / 7) тиж."
        }
    }
}

// MARK: - Per-app section header

private struct AppGroupHeader: View {
    let name: String
    let icon: NSImage?
    let count: Int

    var body: some View {
        HStack(spacing: 9) {
            iconTile
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count)×")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("BrandTintSoft").opacity(0.45))
    }

    @ViewBuilder
    private var iconTile: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary)
                Image(systemName: "app.dashed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 20, height: 20)
        }
    }
}

/// Memoizes app display names and icons so the by-app list doesn't hit NSWorkspace on
/// every re-render (icon lookups touch disk). Held by `@State`, so it survives re-renders.
@Observable
final class AppDisplayCache {
    @ObservationIgnored private var names: [String: String] = [:]
    @ObservationIgnored private var icons: [String: NSImage?] = [:]

    func name(for bundleID: String?) -> String {
        guard let bundleID else { return "Інші застосунки" }
        if let hit = names[bundleID] { return hit }
        let resolved = AppContextProvider.displayName(forBundleID: bundleID)
        names[bundleID] = resolved
        return resolved
    }

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = icons[bundleID] { return hit }
        let resolved = AppContextProvider.icon(forBundleID: bundleID)
        icons[bundleID] = resolved
        return resolved
    }
}
