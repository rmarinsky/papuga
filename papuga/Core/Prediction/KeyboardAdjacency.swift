import Carbon.HIToolbox
import Foundation

/// Physical neighbours of every printable key on an ANSI keyboard, keyed by
/// macOS virtual key code (`kVK_ANSI_*`).
///
/// This is the basis of the **language-agnostic** keystroke typo model: a
/// "fat-finger" mistake is hitting a physically adjacent key. Because it works
/// on key *codes* (not characters), it is identical for QWERTY/ЙЦУКЕН/AZERTY —
/// only the character a key maps to differs per layout. The adjacency is derived
/// once from an approximate physical grid (staggered rows), so left/right,
/// up/down, and diagonal neighbours all fall out of a single distance test.
enum KeyboardAdjacency {
    /// (keyCode, gridX, gridY). Rows are offset to mimic the real stagger so
    /// diagonal neighbours are picked up by the distance test.
    private static let layout: [(code: Int, x: Double, y: Double)] = {
        let rows: [(y: Double, offset: Double, codes: [Int])] = [
            // number row
            (0, 0.0, [kVK_ANSI_Grave, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                      kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
                      kVK_ANSI_0, kVK_ANSI_Minus, kVK_ANSI_Equal]),
            // QWERTY row
            (1, 0.5, [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_T,
                      kVK_ANSI_Y, kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_O, kVK_ANSI_P,
                      kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket]),
            // home row
            (2, 0.75, [kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G,
                       kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
                       kVK_ANSI_Semicolon, kVK_ANSI_Quote]),
            // bottom row
            (3, 1.25, [kVK_ANSI_Z, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B,
                       kVK_ANSI_N, kVK_ANSI_M, kVK_ANSI_Comma, kVK_ANSI_Period,
                       kVK_ANSI_Slash]),
        ]
        var out: [(code: Int, x: Double, y: Double)] = []
        for row in rows {
            for (i, code) in row.codes.enumerated() {
                out.append((code, Double(i) + row.offset, row.y))
            }
        }
        return out
    }()

    /// keyCode → physically adjacent keyCodes (immediate neighbours only).
    static let neighbours: [UInt16: [UInt16]] = {
        let threshold = 1.3 // immediate left/right + both up- and down-diagonals; excludes 2-away
        var map: [UInt16: [UInt16]] = [:]
        for a in layout {
            var near: [UInt16] = []
            for b in layout where b.code != a.code {
                let dx = a.x - b.x
                let dy = a.y - b.y
                if (dx * dx + dy * dy).squareRoot() <= threshold {
                    near.append(UInt16(b.code))
                }
            }
            map[UInt16(a.code)] = near
        }
        return map
    }()

    static func neighbours(of keyCode: UInt16) -> [UInt16] {
        neighbours[keyCode] ?? []
    }
}
