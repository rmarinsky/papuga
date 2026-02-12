import SwiftUI
import Defaults

struct MenuBarView: View {
    @Default(.textReplacementCount) private var textReplacementCount
    @Default(.totalReplacedWords) private var totalReplacedWords
    @Environment(ClipboardHistoryManager.self) private var clipboardHistoryManager
    @Environment(\.openSettings) private var openSettings

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
}
