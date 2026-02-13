import SwiftUI
import Defaults

@main
struct PapugaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.showMenuBarIcon) private var showMenuBarIcon

    @State private var layoutManager = LayoutManager()
    @State private var clipboardHistoryManager = ClipboardHistoryManager()

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environment(layoutManager)
                .environment(clipboardHistoryManager)
                .onAppear {
                    appDelegate.configure(
                        layoutManager: layoutManager,
                        clipboardHistoryManager: clipboardHistoryManager
                    )
                }
        } label: {
            MenuBarIconView()
                .onAppear {
                    appDelegate.configure(
                        layoutManager: layoutManager,
                        clipboardHistoryManager: clipboardHistoryManager
                    )
                }
        }

        Settings {
            SettingsView()
                .environment(layoutManager)
        }
    }
}
