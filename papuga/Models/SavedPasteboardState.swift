import AppKit

struct SavedPasteboardState: Equatable {
    struct Item: Equatable {
        let types: [NSPasteboard.PasteboardType]
        let data: [NSPasteboard.PasteboardType: Data]
    }
    let items: [Item]
    let changeCount: Int
}

extension SavedPasteboardState: Codable {
    private enum CodingKeys: String, CodingKey {
        case items
        case changeCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([Item].self, forKey: .items)
        changeCount = try container.decode(Int.self, forKey: .changeCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encode(changeCount, forKey: .changeCount)
    }
}

extension SavedPasteboardState.Item: Codable {
    private enum CodingKeys: String, CodingKey {
        case types
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawTypes = try container.decode([String].self, forKey: .types)
        let rawData = try container.decode([String: Data].self, forKey: .data)

        types = rawTypes.map { NSPasteboard.PasteboardType($0) }
        data = Dictionary(uniqueKeysWithValues: rawData.map { key, value in
            (NSPasteboard.PasteboardType(key), value)
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(types.map(\.rawValue), forKey: .types)
        try container.encode(
            Dictionary(uniqueKeysWithValues: data.map { key, value in (key.rawValue, value) }),
            forKey: .data
        )
    }
}
