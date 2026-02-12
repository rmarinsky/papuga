import AppKit

struct SavedPasteboardState {
    struct Item {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }
    let items: [Item]
    let changeCount: Int
}
