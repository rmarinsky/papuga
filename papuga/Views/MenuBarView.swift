import SwiftUI
import Defaults

struct MenuBarView: View {
    @Default(.textReplacementCount) private var textReplacementCount
    @Default(.totalReplacedWords) private var totalReplacedWords
    @Default(.clipboardMenuTimeRange) private var clipboardMenuTimeRange
    @Default(.clipboardMenuItemLimit) private var clipboardMenuItemLimit
    @Environment(ClipboardHistoryManager.self) private var clipboardHistoryManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            compactSummaryText

            Divider()

            Menu("Попередні копіопасти") {
                if filteredHistoryEntries.isEmpty {
                    Text("За вибраний період історія порожня")
                } else {
                    ForEach(filteredHistoryEntries) { entry in
                        Button {
                            clipboardHistoryManager.restoreEntry(entry)
                        } label: {
                            Label(historyMenuLabel(for: entry), systemImage: entry.systemImage)
                        }
                    }
                }
            }

            Divider()

            Button("Налаштування...") {
                openSettings()

                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    NSApp.activate(ignoringOtherApps: true)

                    if let settingsWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "ua.com.rmarinsky.papuga.settings" }) {
                        settingsWindow.orderFrontRegardless()
                        settingsWindow.makeKeyAndOrderFront(nil)
                    }
                }
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
            return Calendar.current.isDate(date, inSameDayAs: now)
        case .twoDays, .oneWeek:
            return date >= now.addingTimeInterval(-preset.timeInterval)
        }
    }

    private func historyMenuLabel(for entry: ClipboardHistoryEntry) -> String {
        "\(entry.menuLabel) • \(formattedTimestamp(for: entry.capturedAt))"
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
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter
    }()
}
