import SwiftUI

struct AboutTab: View {
    @ObservedObject private var updaterManager: UpdaterManager

    init() {
        self.updaterManager = AppDelegate.shared?.updaterManager ?? UpdaterManager()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text(Constants.appName)
                .font(.title)
                .bold()

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                Text("Версія \(version) (\(build))")
                    .foregroundStyle(.secondary)
            }

            Text("Перемикач розкладки клавіатури для macOS")
                .foregroundStyle(.secondary)

            Button("Перевірити оновлення…") {
                updaterManager.checkForUpdates()
            }
            .disabled(!updaterManager.canCheckForUpdates)

            Divider()
                .frame(width: 200)

            Text("Автор: Roman Marinskyi")
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
