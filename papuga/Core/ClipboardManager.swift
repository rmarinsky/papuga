import AppKit
import ApplicationServices
import CoreGraphics

final class ClipboardManager {
    private let pasteboard = NSPasteboard.general
    private let logger = AppLogger.clipboard

    func save() -> SavedPasteboardState {
        AppLogger.pre(logger, "save()")
        let changeCount = pasteboard.changeCount
        var items: [SavedPasteboardState.Item] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
            let types = item.types
            for type in types {
                if let data = item.data(forType: type) {
                    dataMap[type] = data
                }
            }
            items.append(SavedPasteboardState.Item(types: types, data: dataMap))
        }

        let state = SavedPasteboardState(items: items, changeCount: changeCount)
        AppLogger.post(logger, "Clipboard state saved: items=\(items.count), changeCount=\(changeCount)")
        return state
    }

    func restore(_ state: SavedPasteboardState) {
        AppLogger.pre(logger, "restore(state changeCount=\(state.changeCount), items=\(state.items.count))")
        pasteboard.clearContents()

        let pasteboardItems: [NSPasteboardItem] = state.items.map { savedItem in
            let item = NSPasteboardItem()
            for type in savedItem.types {
                if let data = savedItem.data[type] {
                    item.setData(data, forType: type)
                }
            }
            return item
        }

        guard !pasteboardItems.isEmpty else {
            AppLogger.warn(logger, "restore() skipped write: no items in saved state")
            return
        }

        let writeSucceeded = pasteboard.writeObjects(pasteboardItems)
        if !writeSucceeded {
            AppLogger.warn(logger, "restore() failed to write pasteboard objects")
            return
        }

        AppLogger.post(logger, "Clipboard state restored")
    }

    func getText() -> String? {
        AppLogger.pre(logger, "getText()")
        let value = pasteboard.string(forType: .string)
        if let value {
            AppLogger.post(logger, "getText() -> \(value.count) chars")
        } else {
            AppLogger.warn(logger, "getText() -> nil")
        }
        return value
    }

    func setText(_ text: String) {
        AppLogger.pre(logger, "setText(\(text.count) chars)")
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        AppLogger.post(logger, "setText completed")
    }

    var changeCount: Int {
        let value = pasteboard.changeCount
        AppLogger.pre(logger, "changeCount queried -> \(value)")
        return value
    }

    func hasSelectedTextInFocusedElement() -> Bool {
        AppLogger.pre(logger, "hasSelectedTextInFocusedElement()")
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?

        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )

        guard focusedResult == .success,
              let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else {
            AppLogger.warn(logger, "Focused UI element is unavailable for selection check")
            return false
        }

        let focusedElement = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        let hasSelection = hasSelectedText(in: focusedElement) || hasNonEmptySelectedRange(in: focusedElement)
        AppLogger.post(logger, "hasSelectedTextInFocusedElement -> \(hasSelection)")
        return hasSelection
    }

    func simulateCopy() {
        AppLogger.pre(logger, "simulateCopy()")
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // C key
        PapugaSyntheticEvent.tag(keyDown)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        PapugaSyntheticEvent.tag(keyUp)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
        AppLogger.post(logger, "simulateCopy posted Cmd+C")
    }

    func simulatePaste() {
        AppLogger.pre(logger, "simulatePaste()")
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        PapugaSyntheticEvent.tag(keyDown)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        PapugaSyntheticEvent.tag(keyUp)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
        AppLogger.post(logger, "simulatePaste posted Cmd+V")
    }

    private func hasSelectedText(in element: AXUIElement) -> Bool {
        AppLogger.pre(logger, "hasSelectedText(in:)")
        var selectedTextRef: CFTypeRef?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextRef
        )

        guard selectedTextResult == .success,
              let selectedText = selectedTextRef as? String else {
            AppLogger.warn(logger, "kAXSelectedText unavailable")
            return false
        }

        let result = !selectedText.isEmpty
        AppLogger.post(logger, "hasSelectedText(in:) -> \(result), length=\(selectedText.count)")
        return result
    }

    private func hasNonEmptySelectedRange(in element: AXUIElement) -> Bool {
        AppLogger.pre(logger, "hasNonEmptySelectedRange(in:)")
        var selectedRangeRef: CFTypeRef?
        let selectedRangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )

        guard selectedRangeResult == .success,
              let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            AppLogger.warn(logger, "kAXSelectedTextRange unavailable")
            return false
        }

        let rangeValue = unsafeBitCast(selectedRangeRef, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else {
            AppLogger.warn(logger, "Selected range has unexpected AXValue type")
            return false
        }

        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else {
            AppLogger.warn(logger, "Unable to decode selected CFRange")
            return false
        }

        let result = range.length > 0
        AppLogger.post(logger, "hasNonEmptySelectedRange(in:) -> \(result), length=\(range.length)")
        return result
    }
}
