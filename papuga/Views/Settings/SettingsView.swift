import SwiftUI

struct SettingsView: View {
    private static let windowIdentifier = NSUserInterfaceItemIdentifier("ua.com.rmarinsky.papuga.settings")
    @State private var positionedWindowID: ObjectIdentifier?

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label("Загальні", systemImage: "gear")
                }

            HotkeysTab()
                .tabItem {
                    Label("Гарячі клавіші", systemImage: "command")
                }

            AnalyticsTab()
                .tabItem {
                    Label("Аналітика", systemImage: "chart.bar")
                }

            AboutTab()
                .tabItem {
                    Label("Про програму", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 320)
        .background(
            SettingsWindowAccessor { window in
                guard let window else { return }
                let id = ObjectIdentifier(window)
                window.identifier = Self.windowIdentifier

                if positionedWindowID != id {
                    positionedWindowID = id
                    window.center()
                }

                bringToFront(window)
            }
        )
        .onAppear {
            if let window = NSApp.windows.first(where: { $0.identifier == Self.windowIdentifier }) {
                bringToFront(window)
            }
        }
        .onDisappear {
            positionedWindowID = nil
        }
    }

    @MainActor
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}
