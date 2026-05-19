import Defaults
import SwiftUI

struct ReplacementsHistorySectionView: View {
    @State private var store = ReplacementHistoryStore.shared
    @State private var filter: FilterOption = .all
    @State private var showingClearConfirmation = false

    @Default(.replacementHistoryEnabled) private var historyEnabled

    enum FilterOption: String, CaseIterable, Identifiable {
        case all, manual, autoFix, autoFixUndone
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Усі"
            case .manual: return "Ручні"
            case .autoFix: return "AutoFix"
            case .autoFixUndone: return "Скасоване AutoFix"
            }
        }

        var kind: ReplacementHistoryEntry.Kind? {
            switch self {
            case .all: return nil
            case .manual: return .manualSwitch
            case .autoFix: return .autoFixApplied
            case .autoFixUndone: return .autoFixUndone
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !historyEnabled {
                disabledView
            } else if filteredEntries.isEmpty {
                emptyView
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        ReplacementRow(entry: entry)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Фільтр", selection: $filter) {
                    ForEach(FilterOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)

                Spacer()

                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Очистити", systemImage: "trash")
                }
                .disabled(store.entries.isEmpty)
                .confirmationDialog(
                    "Очистити історію замін?",
                    isPresented: $showingClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Очистити", role: .destructive) {
                        store.clearAll()
                    }
                    Button("Скасувати", role: .cancel) {}
                } message: {
                    Text("Цю дію не можна скасувати.")
                }
            }

            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
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
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Поки немає записів")
                .font(.headline)
            Text("Зроби перше перемикання або зачекай, поки спрацює автозаміна.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEntries: [ReplacementHistoryEntry] {
        guard let kind = filter.kind else { return store.entries }
        return store.entries.filter { $0.kind == kind }
    }

    private var summaryText: String {
        let total = store.entries.count
        let manual = store.entries.filter { $0.kind == .manualSwitch }.count
        let applied = store.entries.filter { $0.kind == .autoFixApplied }.count
        let undone = store.entries.filter { $0.kind == .autoFixUndone }.count
        return "Усього: \(total)  •  ручних: \(manual)  •  AutoFix: \(applied)  •  скасованих: \(undone)"
    }
}

private struct ReplacementRow: View {
    let entry: ReplacementHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kind.systemImage)
                .frame(width: 22)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.original)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.converted)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 8) {
                    Text(entry.kind.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
                        .foregroundStyle(color)
                    if let bundleID = entry.bundleID, !bundleID.isEmpty {
                        Text(bundleID).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch entry.kind {
        case .manualSwitch: return .blue
        case .autoFixApplied: return .green
        case .autoFixUndone: return .orange
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("dd.MM HH:mm")
        return f
    }()
}
