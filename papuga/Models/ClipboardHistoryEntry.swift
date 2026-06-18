import Foundation

struct ClipboardHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let state: SavedPasteboardState
    let capturedAt: Date
    let title: String
    let subtitle: String?
    let systemImage: String
    let signature: String

    var menuLabel: String {
        guard let subtitle, !subtitle.isEmpty else { return title }
        return "\(title) - \(subtitle)"
    }
}
