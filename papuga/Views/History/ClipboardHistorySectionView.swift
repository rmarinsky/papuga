import SwiftUI

struct ClipboardHistorySectionView: View {
    var compactChrome = false

    @Environment(ClipboardHistoryManager.self) private var clipboardHistoryManager
    @State private var range: HistoryTimeRange = .today
    @State private var searchText: String = ""
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if filteredEntries.isEmpty {
                emptyView
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        ClipboardRow(entry: entry) {
                            clipboardHistoryManager.restoreEntry(entry)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            Picker("", selection: $range) {
                ForEach(HistoryTimeRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Пошук", text: $searchText)
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

            Button(role: .destructive) {
                showingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Очистити копіопасти \(range.clearScopeTitle)")
            .accessibilityLabel("Очистити")
            .disabled(rangeEntries.isEmpty)
            .confirmationDialog(
                "Очистити копіопасти \(range.clearScopeTitle)?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Очистити", role: .destructive) {
                    clearCurrentRange()
                }
                Button("Скасувати", role: .cancel) {}
            } message: {
                Text("Цю дію не можна скасувати.")
            }
        }
        .padding(12)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Історія порожня")
                .font(.headline)
            Text("Скопіюйте щось у буфер обміну, і воно з'явиться тут.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEntries: [ClipboardHistoryEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return rangeEntries }
        return rangeEntries.filter { entry in
            entry.title.lowercased().contains(needle) ||
            (entry.subtitle?.lowercased().contains(needle) ?? false)
        }
    }

    private var rangeEntries: [ClipboardHistoryEntry] {
        let now = Date()
        return clipboardHistoryManager.entries.filter { entry in
            range.contains(entry.capturedAt, now: now)
        }
    }

    private func clearCurrentRange() {
        let now = Date()
        clipboardHistoryManager.clear { entry in
            range.contains(entry.capturedAt, now: now)
        }
    }

}

private struct ClipboardRow: View {
    let entry: ClipboardHistoryEntry
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.systemImage)
                .frame(width: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayText)
                    .font(.body)
                    .lineLimit(2)
            }

            Spacer()

            Text(Self.timeFormatter.string(from: entry.capturedAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                onRestore()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Поставити у буфер")
        }
        .padding(.vertical, 4)
    }

    private var displayText: String {
        if let subtitle = entry.subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return subtitle
        }
        return entry.title
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("dd.MM HH:mm")
        return f
    }()
}
