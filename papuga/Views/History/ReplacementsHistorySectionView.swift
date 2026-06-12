import Defaults
import SwiftUI

struct ReplacementsHistorySectionView: View {
    @State private var store = ReplacementHistoryStore.shared
    @State private var range: TimeRange = .all
    @State private var query: String = ""
    @State private var showingClearConfirmation = false

    @Default(.replacementHistoryEnabled) private var historyEnabled

    enum TimeRange: String, CaseIterable, Identifiable {
        case all, today, week
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Усі"
            case .today: return "Сьогодні"
            case .week: return "Цей тиждень"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !historyEnabled {
                disabledView
            } else if visibleEntries.isEmpty {
                emptyView
            } else {
                List {
                    ForEach(visibleEntries) { entry in
                        ReplacementRow(entry: entry)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(TimeRange.allCases) { chip($0) }
            }

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

    private func chip(_ r: TimeRange) -> some View {
        let selected = range == r
        return Button {
            range = r
        } label: {
            Text(r.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? .white : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(selected ? Color("BrandAccent") : Color(nsColor: .controlBackgroundColor))
                )
        }
        .buttonStyle(.plain)
    }

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

    private var visibleEntries: [ReplacementHistoryEntry] {
        let cal = Calendar.current
        let weekAgo = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date()))
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        return store.entries.filter { entry in
            switch range {
            case .all:
                break
            case .today:
                if !cal.isDateInToday(entry.timestamp) { return false }
            case .week:
                if let weekAgo, entry.timestamp < weekAgo { return false }
            }

            if !q.isEmpty {
                let inText = entry.original.lowercased().contains(q) || entry.converted.lowercased().contains(q)
                let inApp = entry.bundleID.map { AppContextProvider.displayName(forBundleID: $0).lowercased().contains(q) } ?? false
                if !inText && !inApp { return false }
            }
            return true
        }
    }
}

private struct ReplacementRow: View {
    let entry: ReplacementHistoryEntry

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
        }
        .padding(.vertical, 6)
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
