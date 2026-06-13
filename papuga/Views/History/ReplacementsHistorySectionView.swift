import Defaults
import SwiftUI

struct ReplacementsHistorySectionView: View {
    @State private var store = ReplacementHistoryStore.shared
    @State private var range: TimeRange = .week
    @State private var viewMode: ViewMode = .dashboard
    @State private var query: String = ""
    @State private var showingClearConfirmation = false
    @State private var editorSeed: RuleEditorSeed?

    @Default(.replacementHistoryEnabled) private var historyEnabled

    enum ViewMode { case dashboard, list }

    enum TimeRange: String, CaseIterable, Identifiable {
        case today, week, all
        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: return "Сьогодні"
            case .week: return "Тиждень"
            case .all: return "Весь час"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch viewMode {
            case .dashboard: dashboardHeader
            case .list: listHeader
            }
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $editorSeed) { seed in
            RuleEditorSheet(seed: seed) { editorSeed = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !historyEnabled {
            disabledView
        } else {
            switch viewMode {
            case .dashboard:
                if rangeEntries.isEmpty { emptyView } else { dashboard }
            case .list:
                listContent
            }
        }
    }

    // MARK: - Headers

    private var dashboardHeader: some View {
        HStack(spacing: 10) {
            Text("Історія")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Picker("", selection: $range) {
                ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(12)
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            Button { viewMode = .dashboard } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Назад до огляду")

            Text("Усі заміни")
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Пошук", text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.background.tertiary)
            )

            Button(role: .destructive) {
                showingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Очистити історію")
            .disabled(store.entries.isEmpty)
            .confirmationDialog(
                "Очистити історію замін?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Очистити", role: .destructive) { store.clearAll() }
                Button("Скасувати", role: .cancel) {}
            } message: {
                Text("Цю дію не можна скасувати.")
            }
        }
        .padding(12)
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    mostCommonCard
                    firstSeenCard
                }
                byAppCard
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var mostCommonCard: some View {
        SectionCard(eyebrow: "ЧАСТО", title: "Найчастіші помилки") {
            if mostCommon.isEmpty {
                hint("Поки що немає повторюваних помилок у цьому періоді.")
            } else {
                VStack(spacing: 9) {
                    ForEach(mostCommon) { pair in
                        CommonPairRow(pair: pair, maxCount: maxCommonCount) {
                            editorSeed = RuleEditorSeed(source: pair.source, target: pair.target, mode: .replace)
                        }
                    }
                }
            }
        }
    }

    private var firstSeenCard: some View {
        SectionCard(eyebrow: "ВПЕРШЕ", title: "Нові помилки") {
            if firstSeen.isEmpty {
                hint("Тут з'являться помилки, які Papuga побачить уперше.")
            } else {
                VStack(spacing: 9) {
                    ForEach(firstSeen) { pair in
                        FirstSeenRow(pair: pair) {
                            editorSeed = RuleEditorSeed(source: pair.source, target: pair.target, mode: .replace)
                        }
                    }
                }
            }
        }
    }

    private var byAppCard: some View {
        SectionCard(
            eyebrow: "ПО ЗАСТОСУНКАХ",
            title: "Де ти помиляєшся найчастіше"
        ) {
            if byApp.isEmpty {
                hint("Поки немає даних по застосунках.")
            } else {
                VStack(spacing: 10) {
                    ForEach(byApp) { app in
                        AppRow(app: app, maxCount: maxAppCount)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Наведи на пару, щоб зробити з неї правило.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button { viewMode = .list } label: {
                HStack(spacing: 4) {
                    Text("Показати всі заміни")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color("BrandAccentDeep"))
        }
        .padding(.top, 2)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Full chronological list

    @ViewBuilder
    private var listContent: some View {
        if visibleEntries.isEmpty {
            emptyView
        } else {
            List {
                ForEach(visibleEntries) { entry in
                    ReplacementRow(entry: entry) { seed in editorSeed = seed }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Empty / disabled states

    private var disabledView: some View {
        VStack(spacing: 8) {
            Image(systemName: "pause.circle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Запис історії вимкнено")
                .font(.headline)
            Text("Увімкніть «Зберігати історію замін» у вкладці «Загальні», щоб тут з'являлися записи.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Поки немає записів" : "Нічого не знайдено")
                .font(.headline)
            if query.isEmpty {
                Text("Зроби перше перемикання або зачекай, поки спрацює автозаміна.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived data

    private var rangeEntries: [ReplacementHistoryEntry] {
        let cal = Calendar.current
        let weekAgo = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date()))
        return store.entries.filter { entry in
            switch range {
            case .all:
                return true
            case .today:
                return cal.isDateInToday(entry.timestamp)
            case .week:
                if let weekAgo { return entry.timestamp >= weekAgo }
                return true
            }
        }
    }

    private var visibleEntries: [ReplacementHistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rangeEntries }
        return rangeEntries.filter { entry in
            let inText = entry.original.lowercased().contains(q) || entry.converted.lowercased().contains(q)
            let inApp = entry.bundleID.map { AppContextProvider.displayName(forBundleID: $0).lowercased().contains(q) } ?? false
            return inText || inApp
        }
    }

    private var mostCommon: [AggregatedPair] {
        Array(
            aggregatePairs(rangeEntries)
                .filter { $0.count >= 2 }
                .sorted { $0.count > $1.count }
                .prefix(6)
        )
    }

    private var maxCommonCount: Int { mostCommon.map(\.count).max() ?? 1 }

    private var firstSeen: [AggregatedPair] {
        Array(
            aggregatePairs(rangeEntries)
                .sorted { $0.firstSeen > $1.firstSeen }
                .prefix(6)
        )
    }

    private var byApp: [AppCount] {
        var counts: [String: Int] = [:]
        for entry in rangeEntries where isMistakeEntry(entry) {
            counts[entry.bundleID ?? "—", default: 0] += 1
        }
        return Array(
            counts.map { key, count -> AppCount in
                let bundleID = key == "—" ? nil : key
                let name = bundleID.map { AppContextProvider.displayName(forBundleID: $0) } ?? "Без застосунку"
                return AppCount(id: key, name: name, bundleID: bundleID, count: count)
            }
            .sorted { $0.count > $1.count }
            .prefix(6)
        )
    }

    private var maxAppCount: Int { byApp.map(\.count).max() ?? 1 }
}

// MARK: - Aggregation

private struct AggregatedPair: Identifiable {
    let id: String
    let source: String
    let target: String
    let count: Int
    let firstSeen: Date
    let lastBundleID: String?
}

private struct AppCount: Identifiable {
    let id: String
    let name: String
    let bundleID: String?
    let count: Int
}

/// A "mistake" worth aggregating: an applied switch/fix with both sides intact.
/// Undone auto-fixes (false positives) and truncated entries are excluded.
private func isMistakeEntry(_ entry: ReplacementHistoryEntry) -> Bool {
    entry.kind != .autoFixUndone
        && !entry.originalTruncated
        && !entry.convertedTruncated
        && !entry.original.isEmpty
        && !entry.converted.isEmpty
}

private func aggregatePairs(_ entries: [ReplacementHistoryEntry]) -> [AggregatedPair] {
    struct Acc {
        var count: Int
        var first: ReplacementHistoryEntry
        var last: ReplacementHistoryEntry
    }
    var map: [String: Acc] = [:]
    for entry in entries where isMistakeEntry(entry) {
        let key = entry.original.lowercased() + "\u{2192}" + entry.converted.lowercased()
        if var acc = map[key] {
            acc.count += 1
            if entry.timestamp < acc.first.timestamp { acc.first = entry }
            if entry.timestamp > acc.last.timestamp { acc.last = entry }
            map[key] = acc
        } else {
            map[key] = Acc(count: 1, first: entry, last: entry)
        }
    }
    return map.map { key, acc in
        AggregatedPair(
            id: key,
            source: acc.last.original,
            target: acc.last.converted,
            count: acc.count,
            firstSeen: acc.first.timestamp,
            lastBundleID: acc.last.bundleID
        )
    }
}

// MARK: - Dashboard rows

private struct CommonPairRow: View {
    let pair: AggregatedPair
    let maxCount: Int
    let onMakeRule: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ReplacementReceipt(source: pair.source, target: pair.target, strikethroughSource: true)
            Spacer(minLength: 6)
            VolumeBar(ratio: Double(pair.count) / Double(max(1, maxCount)))
                .frame(width: 40)
            Text("×\(pair.count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 26, alignment: .trailing)
            MakeRuleButton(visible: hovering, action: onMakeRule)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct FirstSeenRow: View {
    let pair: AggregatedPair
    let onMakeRule: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ReplacementReceipt(source: pair.source, target: pair.target, strikethroughSource: true)
            if isNew { NewBadge() }
            Spacer(minLength: 6)
            Text(meta)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            MakeRuleButton(visible: hovering, action: onMakeRule)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var isNew: Bool {
        pair.firstSeen > Date().addingTimeInterval(-24 * 3600)
    }

    private var meta: String {
        let when = Self.relativeFormatter.localizedString(for: pair.firstSeen, relativeTo: Date())
        if let bundleID = pair.lastBundleID {
            return "\(when) · \(AppContextProvider.displayName(forBundleID: bundleID))"
        }
        return when
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

private struct AppRow: View {
    let app: AppCount
    let maxCount: Int

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 18, height: 18)
            Text(app.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            VolumeBar(ratio: Double(app.count) / Double(max(1, maxCount)))
                .frame(maxWidth: 160)
            Text("\(app.count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let bundleID = app.bundleID, let icon = AppContextProvider.icon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Small shared bits

private struct VolumeBar: View {
    let ratio: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color("BrandAccent"))
                    .frame(width: max(3, geo.size.width * min(1, max(0, ratio))))
            }
        }
        .frame(height: 6)
    }
}

private struct NewBadge: View {
    var body: some View {
        Text("Нове")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color("BrandAccent")))
    }
}

private struct MakeRuleButton: View {
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color("BrandAccentDeep"))
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .frame(width: 16)
        .help("Зробити правило з цієї пари")
    }
}

// MARK: - Chronological row

private struct ReplacementRow: View {
    let entry: ReplacementHistoryEntry
    let onEdit: (RuleEditorSeed) -> Void

    var body: some View {
        HStack(spacing: 12) {
            appGlyph
                .frame(width: 18, height: 18)

            Text(entry.original)
                .font(.system(.body, design: .monospaced))
                .strikethrough(true, color: Color("BrandAccentDeep").opacity(0.7))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(Color("BrandAccentDeep"))

            Text(entry.converted)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(entry.kind == .autoFixUndone ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            if let appName {
                Text(appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(relativeDay)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 56, alignment: .trailing)

            if canMakeWordAction {
                Menu {
                    rowActions
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Дії із цим словом")
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            if canMakeWordAction {
                rowActions
            }
        }
    }

    // MARK: - Per-row actions (route through the rule editor modal)

    @ViewBuilder
    private var rowActions: some View {
        if canMakeRule {
            Button {
                onEdit(RuleEditorSeed(source: trimmedOriginal, target: trimmedConverted, mode: .replace))
            } label: {
                Label("Зробити правило…", systemImage: "wand.and.stars")
            }
        }
        Button {
            onEdit(RuleEditorSeed(source: trimmedOriginal, mode: .leaveAlone))
        } label: {
            Label("Не чіпати «\(trimmedOriginal)»", systemImage: "hand.raised")
        }
    }

    private var trimmedOriginal: String {
        entry.original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedConverted: String {
        entry.converted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Allowlisting/rules act on a single typed word — the unit auto-fix evaluates.
    /// Multi-word or truncated entries can't be expressed as a word/rule.
    private var canMakeWordAction: Bool {
        !entry.originalTruncated
            && trimmedOriginal.count >= 2
            && !trimmedOriginal.contains(where: { $0.isWhitespace })
    }

    private var canMakeRule: Bool {
        canMakeWordAction
            && !entry.convertedTruncated
            && !trimmedConverted.isEmpty
            && !trimmedConverted.contains(where: { $0.isWhitespace })
            && trimmedConverted.lowercased() != trimmedOriginal.lowercased()
    }

    @ViewBuilder
    private var appGlyph: some View {
        if let bundleID = entry.bundleID, !bundleID.isEmpty,
           let icon = AppContextProvider.icon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(entry.kind == .autoFixUndone ? .orange : Color("BrandAccentDeep"))
        }
    }

    private var appName: String? {
        guard let bundleID = entry.bundleID, !bundleID.isEmpty else { return nil }
        return AppContextProvider.displayName(forBundleID: bundleID)
    }

    private var relativeDay: String {
        let cal = Calendar.current
        if cal.isDateInToday(entry.timestamp) { return "Сьогодні" }
        if cal.isDateInYesterday(entry.timestamp) { return "Вчора" }
        return entry.timestamp.formatted(.dateTime.weekday(.abbreviated))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("HH:mm")
        return f
    }()
}
