import CoreGraphics
import Carbon.HIToolbox
import Defaults

final class HotkeyListener {
    var onSwitch: ((SwitchDirection) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let logger = AppLogger.hotkey

    private var lastShortcutPressTime: TimeInterval = 0
    private var shortcutPressCount: Int = 0

    private var previousFlags: CGEventFlags = []

    deinit {
        stop()
    }

    func start() {
        AppLogger.pre(logger, "start() called")
        guard eventTap == nil else {
            AppLogger.warn(logger, "start() skipped: event tap already active")
            return
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: userInfo
        ) else {
            AppLogger.error(logger, "CGEvent.tapCreate failed")
            return
        }

        AppLogger.action(logger, "CGEvent tap created successfully")
        eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLogger.post(logger, "Hotkey event tap enabled and attached to run loop")
    }

    func stop() {
        AppLogger.pre(logger, "stop() called")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
            AppLogger.action(logger, "Hotkey event tap disabled and removed")
        } else {
            AppLogger.warn(logger, "stop() called with no active event tap")
        }
        resetState()
        AppLogger.post(logger, "stop() completed")
    }

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        AppLogger.pre(logger, "handleEvent(type: \(String(describing: type.rawValue)))")
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                AppLogger.action(logger, "Event tap was disabled by system and has been re-enabled")
            }
            return Unmanaged.passUnretained(event)
        }

        guard Defaults[.isServiceRunning] else {
            AppLogger.warn(logger, "Ignoring event: service is not running")
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            AppLogger.action(logger, "keyDown detected -> resetting shortcut state")
            resetState()
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            AppLogger.warn(logger, "Ignoring unsupported event type: \(String(describing: type.rawValue))")
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let previous = previousFlags
        let now = ProcessInfo.processInfo.systemUptime
        let interval = Defaults[.doublePressInterval]

        let preset = currentPreset()
        let required = requiredFlags(for: preset)
        let forbidden = forbiddenFlags(for: preset)
        AppLogger.action(logger, "Evaluating flags for preset: \(preset.rawValue)")

        let isActive = flags.contains(required) && flags.intersection(forbidden).isEmpty
        let wasActive = previous.contains(required) && previous.intersection(forbidden).isEmpty

        // Count "tap" on deactivation of the selected chord.
        if wasActive && !isActive {
            AppLogger.action(logger, "Detected chord deactivation tap")
            if (now - lastShortcutPressTime) < interval && shortcutPressCount >= 1 {
                shortcutPressCount = 0
                lastShortcutPressTime = 0
                previousFlags = flags
                AppLogger.post(logger, "Double-tap detected -> emitting switch forward")
                onSwitch?(.forward)
                return Unmanaged.passUnretained(event)
            }

            shortcutPressCount = 1
            lastShortcutPressTime = now
            AppLogger.post(logger, "First tap stored, waiting for second tap")
        }

        previousFlags = flags
        AppLogger.post(logger, "handleEvent completed")
        return Unmanaged.passUnretained(event)
    }

    private func resetState() {
        AppLogger.pre(logger, "resetState()")
        shortcutPressCount = 0
        lastShortcutPressTime = 0
        AppLogger.post(logger, "Shortcut state reset")
    }

    private func currentPreset() -> DoublePressShortcutPreset {
        DoublePressShortcutPreset(rawValue: Defaults[.doublePressShortcut]) ?? .optionShift
    }

    private func requiredFlags(for preset: DoublePressShortcutPreset) -> CGEventFlags {
        switch preset {
        case .optionShift:
            return [.maskAlternate, .maskShift]
        case .commandShift:
            return [.maskCommand, .maskShift]
        case .controlShift:
            return [.maskControl, .maskShift]
        }
    }

    private func forbiddenFlags(for preset: DoublePressShortcutPreset) -> CGEventFlags {
        switch preset {
        case .optionShift:
            return [.maskControl, .maskCommand]
        case .commandShift:
            return [.maskControl, .maskAlternate]
        case .controlShift:
            return [.maskCommand, .maskAlternate]
        }
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let listener = Unmanaged<HotkeyListener>.fromOpaque(userInfo).takeUnretainedValue()
    return listener.handleEvent(proxy: proxy, type: type, event: event)
}
