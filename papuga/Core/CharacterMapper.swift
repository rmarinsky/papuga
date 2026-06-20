import Carbon.HIToolbox
import Foundation

struct KeyMapping {
    let keyCode: UInt16
    let needsShift: Bool
}

struct KeycodeCharacters {
    let normal: Character?
    let shifted: Character?
}

final class CharacterMapper {
    private var forwardMaps: [String: [Character: KeyMapping]] = [:]
    private var reverseMaps: [String: [UInt16: KeycodeCharacters]] = [:]
    private let logger = AppLogger.mapper

    func buildMap(for source: TISInputSource, sourceID: String) {
        AppLogger.pre(logger, "buildMap(sourceID: \(sourceID))")
        if forwardMaps[sourceID] != nil {
            AppLogger.post(logger, "buildMap skipped: cache hit for \(sourceID)")
            return
        }

        guard let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            AppLogger.warn(logger, "buildMap aborted: layoutData missing for \(sourceID)")
            return
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue()
        let dataPtr = CFDataGetBytePtr(layoutData)!
        let keyboardLayout = dataPtr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
        let keyboardType = UInt32(LMGetKbdType())

        var forwardMap: [Character: KeyMapping] = [:]
        var reverseMap: [UInt16: KeycodeCharacters] = [:]

        for keyCode in 0...Constants.maxKeyCode {
            let normalChar = characterForKeyCode(keyCode, shift: false, layout: keyboardLayout, keyboardType: keyboardType)
            let shiftedChar = characterForKeyCode(keyCode, shift: true, layout: keyboardLayout, keyboardType: keyboardType)

            reverseMap[keyCode] = KeycodeCharacters(normal: normalChar, shifted: shiftedChar)

            if let char = normalChar {
                if forwardMap[char] == nil {
                    forwardMap[char] = KeyMapping(keyCode: keyCode, needsShift: false)
                }
            }
            if let char = shiftedChar {
                if forwardMap[char] == nil {
                    forwardMap[char] = KeyMapping(keyCode: keyCode, needsShift: true)
                }
            }
        }

        forwardMaps[sourceID] = forwardMap
        reverseMaps[sourceID] = reverseMap
        AppLogger.post(logger, "buildMap completed for \(sourceID): forward=\(forwardMap.count), reverse=\(reverseMap.count)")
    }

    func convert(text: String, fromSourceID: String, toSourceID: String) -> String {
        AppLogger.pre(logger, "convert(textCount: \(text.count), from: \(fromSourceID), to: \(toSourceID))")
        guard let sourceForward = forwardMaps[fromSourceID],
              let targetReverse = reverseMaps[toSourceID] else {
            AppLogger.warn(logger, "convert fallback: missing maps for source/target")
            return text
        }

        var converted = ""
        converted.reserveCapacity(text.count)
        for char in text {
            guard let mapping = sourceForward[char] else {
                converted.append(char)
                continue
            }
            guard let targetChars = targetReverse[mapping.keyCode] else {
                converted.append(char)
                continue
            }
            converted.append(mapping.needsShift ? (targetChars.shifted ?? char) : (targetChars.normal ?? char))
        }
        AppLogger.post(logger, "convert completed: outputCount=\(converted.count)")
        return converted
    }

    /// The key a character is produced by, in a given layout. Used by the
    /// keystroke (keyboard-adjacency) typo model to find which physical key the
    /// user actually pressed.
    func mapping(for character: Character, sourceID: String) -> KeyMapping? {
        forwardMaps[sourceID]?[character]
    }

    /// The characters a physical key produces in a given layout (normal +
    /// shifted) — the inverse of `mapping(for:)`.
    func characters(forKeyCode keyCode: UInt16, sourceID: String) -> KeycodeCharacters? {
        reverseMaps[sourceID]?[keyCode]
    }

    func hasMap(for sourceID: String) -> Bool {
        forwardMaps[sourceID] != nil
    }

    func invalidateCache() {
        AppLogger.pre(logger, "invalidateCache()")
        forwardMaps.removeAll()
        reverseMaps.removeAll()
        AppLogger.post(logger, "All character maps invalidated")
    }

    func invalidateCache(for sourceID: String) {
        AppLogger.pre(logger, "invalidateCache(for: \(sourceID))")
        forwardMaps.removeValue(forKey: sourceID)
        reverseMaps.removeValue(forKey: sourceID)
        AppLogger.post(logger, "Character maps invalidated for \(sourceID)")
    }

    private func characterForKeyCode(
        _ keyCode: UInt16,
        shift: Bool,
        layout: UnsafePointer<UCKeyboardLayout>,
        keyboardType: UInt32
    ) -> Character? {
        let modifierKeyState: UInt32 = shift ? (UInt32(shiftKey >> 8) & 0xFF) : 0
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            modifierKeyState,
            keyboardType,
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }

        guard let scalar = UnicodeScalar(chars[0]) else { return nil }
        let character = Character(scalar)

        if character.isNewline || character.asciiValue == 0 {
            return nil
        }

        return character
    }
}
