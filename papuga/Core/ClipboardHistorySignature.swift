import Foundation

enum ClipboardHistorySignature {
    static func make(for state: SavedPasteboardState) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037

        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        func mix(_ value: Int) {
            var raw = UInt64(value).littleEndian
            withUnsafeBytes(of: &raw) { bytes in
                for byte in bytes { mix(byte) }
            }
        }

        func mix(_ string: String) {
            for byte in string.utf8 { mix(byte) }
            mix(0)
        }

        mix(state.items.count)
        for item in state.items {
            let sortedTypes = item.types.sorted { $0.rawValue < $1.rawValue }
            mix(sortedTypes.count)

            for type in sortedTypes {
                mix(type.rawValue)
                guard let data = item.data[type] else {
                    mix(0)
                    continue
                }

                mix(data.count)
                for byte in data.prefix(128) { mix(byte) }
                if data.count > 128 {
                    for byte in data.suffix(64) { mix(byte) }
                }
            }
        }

        return String(format: "%016llx", hash)
    }
}
