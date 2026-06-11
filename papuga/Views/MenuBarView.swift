import SwiftUI
import Defaults

struct MenuBarView: View {
    @Default(.textReplacementCount) private var textReplacementCount
    @Default(.totalReplacedWords) private var totalReplacedWords
    @Default(.clipboardMenuTimeRange) private var clipboardMenuTimeRange
    @Default(.clipboardMenuItemLimit) private var clipboardMenuItemLimit
    @Default(.autoFixEnabled) private var autoFixEnabled
    @Environment(ClipboardHistoryManager.self) private var clipboardHistoryManager
    @ObservedObject private var updaterManager: UpdaterManager

    init() {
        self.updaterManager = AppDelegate.shared?.updaterManager ?? UpdaterManager()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            compactSummaryText

            Divider()

            Toggle("Автозаміна під час набору", isOn: $autoFixEnabled)

            Divider()

            Menu("Попередні копіопасти") {
                let entries = filteredHistoryEntries
                if entries.isEmpty {
                    Text("За вибраний період історія порожня")
                } else {
                    ForEach(entries) { entry in
                        Button {
                            clipboardHistoryManager.restoreEntry(entry)
                        } label: {
                            Label(historyMenuLabel(for: entry), systemImage: entry.systemImage)
                        }
                    }
                }
            }

            Divider()

            Button("Перевірити оновлення...") {
                updaterManager.checkForUpdates()
            }
            .disabled(!updaterManager.canCheckForUpdates)

            Button("Відкрити Papuga...") {
                HistoryWindowController.shared.showHistory(initialSection: .overview)
            }

            Button("Налаштування...") {
                HistoryWindowController.shared.showHistory(initialSection: .settingsGeneral)
            }

            Divider()

            Button("Вийти") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .onAppear {
            clipboardHistoryManager.refreshNow()
        }
    }

    private var compactSummaryText: some View {
        (
            Text("+")
            + Text("\(estimatedSecondsSaved)").bold()
            + Text(" сек до життя")
        )
        .monospacedDigit()
    }

    private var estimatedSecondsSaved: Int {
        Constants.estimatedSecondsSaved(replacementCount: textReplacementCount, totalWords: totalReplacedWords)
    }

    private var filteredHistoryEntries: [ClipboardHistoryEntry] {
        let preset = ClipboardHistoryRetentionPreset(rawValue: clipboardMenuTimeRange) ?? .oneDay
        let now = Date()

        let entriesInRange = clipboardHistoryManager.entries.filter { entry in
            isWithinMenuTimeRange(entry.capturedAt, now: now, preset: preset)
        }

        if clipboardMenuItemLimit <= 0 {
            return entriesInRange
        }

        return Array(entriesInRange.prefix(clipboardMenuItemLimit))
    }

    private func isWithinMenuTimeRange(
        _ date: Date,
        now: Date,
        preset: ClipboardHistoryRetentionPreset
    ) -> Bool {
        switch preset {
        case .oneHour:
            return date >= now.addingTimeInterval(-preset.timeInterval)
        case .oneDay:
            return date >= now.addingTimeInterval(-preset.timeInterval)
        case .twoDays, .oneWeek:
            return date >= now.addingTimeInterval(-preset.timeInterval)
        }
    }

    private func historyMenuLabel(for entry: ClipboardHistoryEntry) -> String {
        "\(formattedTimestamp(for: entry.capturedAt)) • \(entry.menuLabel)"
    }

    private func formattedTimestamp(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dayTimeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("dd.MM HH:mm")
        return formatter
    }()
}
