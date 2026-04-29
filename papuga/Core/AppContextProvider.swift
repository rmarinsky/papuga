import AppKit
import Foundation

enum AppContextProvider {
    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    static func runningAppCandidates() -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier,
                  let name = app.localizedName,
                  app.activationPolicy == .regular else {
                return nil
            }
            return (id, name)
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}
