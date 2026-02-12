import Foundation

struct ClipboardHistoryEntry: Identifiable {
    let id: UUID
    let state: SavedPasteboardState
    let capturedAt: Date
    let title: String
    let subtitle: String?
    let systemImage: String
    let signature: Int

    var menuLabel: String {
        guard let subtitle, !subtitle.isEmpty else { return title }
        return "\(title) - \(subtitle)"
    }
}
