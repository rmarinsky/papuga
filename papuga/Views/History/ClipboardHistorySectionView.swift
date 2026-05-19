import Defaults
import SwiftUI

struct ClipboardHistorySectionView: View {
    @Environment(ClipboardHistoryManager.self) private var clipboardHistoryManager
    @Default(.clipboardHistoryRetention) private var clipboardHistoryRetention
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

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
            Text(retentionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            TextField("Пошук", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
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
        guard !needle.isEmpty else { return clipboardHistoryManager.entries }
        return clipboardHistoryManager.entries.filter { entry in
            entry.title.lowercased().contains(needle) ||
            (entry.subtitle?.lowercased().contains(needle) ?? false)
        }
    }

    private var retentionDescription: String {
        let preset = ClipboardHistoryRetentionPreset(rawValue: clipboardHistoryRetention) ?? .oneDay
        return "Зберігається \(preset.title.lowercased()). \(clipboardHistoryManager.entries.count) \(pluralize(clipboardHistoryManager.entries.count))"
    }

    private func pluralize(_ n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "запис" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "записи" }
        return "записів"
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
                Text(entry.title).font(.body)
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("dd.MM HH:mm")
        return f
    }()
}
