import SwiftUI
import Defaults

struct MenuBarView: View {
    @Default(.textReplacementCount) private var textReplacementCount
    @Default(.totalReplacedWords) private var totalReplacedWords
    @Environment(ClipboardHistoryManager.self) private var clipboardHistoryManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            compactSummaryText

            Divider()

            Menu("Попередні копіпасти") {
                if clipboardHistoryManager.entries.isEmpty {
                    Text("Історія порожня")
                } else {
                    ForEach(Array(clipboardHistoryManager.entries.prefix(15))) { entry in
                        Button {
                            clipboardHistoryManager.restoreEntry(entry)
                        } label: {
                            Label(entry.menuLabel, systemImage: entry.systemImage)
                        }
                    }
                }
            }

            Divider()

            SettingsLink {
                Text("Налаштування...")
            }

            Divider()

            Button("Вийти") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
    }

    private var compactSummaryText: some View {
        (
            Text("+")
            + Text("\(estimatedSecondsSaved)").bold()
            + Text(" сек до життя")
        )
        .monospacedDigit()
    }

    private var averageWordsPerReplacement: Double {
        guard textReplacementCount > 0 else { return 0 }
        return Double(totalReplacedWords) / Double(textReplacementCount)
    }

    private var estimatedSecondsSaved: Int {
        let estimated = Double(textReplacementCount) * averageWordsPerReplacement * Constants.estimatedManualReplacementSecondsPerWord
        return Int(estimated.rounded())
    }
}
