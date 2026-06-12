import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Defaults
import Foundation

@MainActor
final class AutoFixController {
    private let layoutManager: LayoutManager
    private let characterMapper: CharacterMapper
    private let logger = AppLogger.autoFix

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var buffer = WordBuffer()
    private var lastFix: PendingUndo?
    private var sessionRejected = Set<String>()

    init(layoutManager: LayoutManager, characterMapper: CharacterMapper) {
        self.layoutManager = layoutManager
        self.characterMapper = characterMapper
    }

    func start() {
        AppLogger.pre(logger, "AutoFixController.start()")
        guard eventTap == nil else {
            AppLogger.warn(logger, "start() skipped: tap already active")
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: autoFixCallback,
            userInfo: userInfo
        ) else {
            AppLogger.error(logger, "CGEvent.tapCreate failed for AutoFixController")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLogger.post(logger, "AutoFixController tap attached")
    }

    func stop() {
        AppLogger.pre(logger, "AutoFixController.stop()")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        buffer.reset()
        lastFix = nil
        AppLogger.post(logger, "AutoFixController stopped")
    }

    /// Undo the most recent auto-fix on demand (e.g. from a global shortcut),
    /// if one is still pending. Restores the original word and layout.
    func undoLastFix() {
        guard let pending = lastFix else {
            AppLogger.post(logger, "undoLastFix() ignored: no pending fix")
            return
        }
        undo(pending, boundaryAlreadyConsumed: false)
        lastFix = nil
    }

    fileprivate nonisolated func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                guard let tap = self?.eventTap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let timestamp = ProcessInfo.processInfo.systemUptime
        let typedString = readTypedString(from: event)

        DispatchQueue.main.async { [weak self] in
            self?.processEvent(type: type, keyCode: keyCode, flags: flags, typedString: typedString, timestamp: timestamp)
        }
    }

    private nonisolated func readTypedString(from event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: chars, count: length)
    }

    private func processEvent(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, typedString: String, timestamp: TimeInterval) {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            // If the click is on our undo toast, let SwiftUI's Button handle it.
            // Resetting lastFix here would null out the pending undo before the
            // Button action can fire, defeating the toast.
            if FixToastCoordinator.shared.isMouseOverToast() {
                return
            }
            buffer.reset()
            lastFix = nil
            return
        case .keyDown:
            break
        default:
            return
        }

        if flags.contains(.maskCommand) {
            buffer.reset()
            lastFix = nil
            return
        }

        if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            handleBackspace(timestamp: timestamp)
            return
        }

        if isResetKey(keyCode) {
            buffer.reset()
            lastFix = nil
            return
        }

        if isWordBoundary(keyCode: keyCode, typedString: typedString) {
            evaluateAndMaybeFix(boundary: typedString)
            buffer.reset()
            return
        }

        if !typedString.isEmpty {
            buffer.append(string: typedString, keyCode: keyCode)
        }
    }

    private func handleBackspace(timestamp: TimeInterval) {
        if let pending = lastFix {
            let elapsed = timestamp - pending.timestamp
            let window = Defaults[.autoFixUndoWindow]
            if elapsed <= window {
                // Backspace already deleted the trailing boundary char; only the
                // replacement word remains to be removed.
                undo(pending, boundaryAlreadyConsumed: true)
                lastFix = nil
                return
            }
        }
        buffer.popLast()
    }

    private func undoAndAddToAllowlist() {
        guard let pending = lastFix else { return }
        let normalized = pending.original.lowercased()
        var list = Defaults[.autoFixAllowlist]
        if !list.contains(where: { $0.lowercased() == normalized }) {
            list.append(pending.original)
            Defaults[.autoFixAllowlist] = list
            AppLogger.action(logger, "Added '\(pending.original)' to allowlist via toast click")
        }
        // Toast click: replacement + boundary are still in the buffer.
        undo(pending, boundaryAlreadyConsumed: false)
        lastFix = nil
    }

    private func undo(_ pending: PendingUndo, boundaryAlreadyConsumed: Bool) {
        AppLogger.action(logger, "Undoing recent auto-fix: \(pending.replacement) -> \(pending.original)")
        let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - pending.timestamp) * 1000)
        sessionRejected.insert(pending.original)
        layoutManager.switchTo(pending.fromLayoutID)
        if boundaryAlreadyConsumed {
            deleteCharacters(count: pending.replacement.count)
            typeText(pending.original)
        } else {
            deleteCharacters(count: pending.replacement.count + pending.boundary.count)
            typeText(pending.original + pending.boundary)
        }
        AnalyticsCounters.reverseReplacement(text: pending.replacement)

        let bundleID = AppContextProvider.frontmostBundleID()
        PapugaEventLog.shared.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixUndone,
            frontmostBundleID: bundleID,
            inputLayout: layoutManager.getCurrentLayoutID(),
            properties: [
                "original_length": .int(pending.original.count),
                "time_to_undo_ms": .int(elapsedMs)
            ]
        ))

        ReplacementHistoryStore.shared.record(
            ReplacementHistoryEntry(
                kind: .autoFixUndone,
                original: pending.original,
                converted: pending.replacement,
                sourceLayoutID: pending.fromLayoutID,
                targetLayoutID: nil,
                bundleID: bundleID
            )
        )
    }

    private func evaluateAndMaybeFix(boundary: String) {
        let word = buffer.text
        guard !word.isEmpty else { return }

        let bundleID = AppContextProvider.frontmostBundleID() ?? ""
        if Defaults[.autoFixBlocklist].contains(bundleID) {
            logSkip(.blocklist, word: word, bundleID: bundleID)
            return
        }

        if AutoFixDecision.isInAllowlist(word, allowlist: Defaults[.autoFixAllowlist]) {
            logSkip(.allowlist, word: word, bundleID: bundleID)
            return
        }

        if let rule = Defaults[.customAutoReplaceRules].first(where: { $0.matches(word) }) {
            applyCustomRule(rule: rule, original: word, boundary: boundary, bundleID: bundleID)
            return
        }

        if let skip = AutoFixDecision.shouldSkipWord(word, minLength: Defaults[.autoFixMinWordLength]) {
            switch skip {
            case .tooShort:
                logSkip(.tooShort, word: word, bundleID: bundleID); return
            case .containsDigits, .containsForbiddenChars:
                logSkip(.containsDigits, word: word, bundleID: bundleID); return
            }
        }
        if sessionRejected.contains(word) {
            logSkip(.recentlyRejected, word: word, bundleID: bundleID); return
        }

        let currentID = layoutManager.getCurrentLayoutID()
        guard let targetID = layoutManager.nextLayout(after: currentID, direction: .forward),
              targetID != currentID else {
            logSkip(.noTargetLayout, word: word, bundleID: bundleID); return
        }
        guard let currentSrc = layoutManager.sourceForID(currentID),
              let targetSrc = layoutManager.sourceForID(targetID) else {
            logSkip(.missingMaps, word: word, bundleID: bundleID); return
        }

        characterMapper.buildMap(for: currentSrc, sourceID: currentID)
        characterMapper.buildMap(for: targetSrc, sourceID: targetID)
        let candidate = characterMapper.convert(text: word, fromSourceID: currentID, toSourceID: targetID)

        if candidate == word {
            logSkip(.identicalCandidate, word: word, bundleID: bundleID); return
        }

        let currentLang = languageHintForLayoutID(currentID)
        let targetLang = languageHintForLayoutID(targetID)

        // Hard guard against false positives like `faster` -> `афіеук`. If the
        // original is a real word in the current layout's language, the user
        // intended to type it; never replace.
        if AutoFixDecision.isCorrectlySpelled(word, language: currentLang) {
            logSkip(.originalIsRealWord, word: word, bundleID: bundleID, extra: [
                "from_lang": .string(currentLang)
            ])
            return
        }

        let algorithm = (LanguageScorerAlgorithm(rawValue: Defaults[.autoFixAlgorithm]) ?? .appleNL).resolvedImplementation
        let scorer = LanguageScorerFactory.make(algorithm)
        let scoreOriginal = scorer.score(word, expecting: currentLang)
        let scoreCandidate = scorer.score(candidate, expecting: targetLang)
        let threshold = Defaults[.autoFixThreshold]

        AppLogger.post(logger, "Eval word=\(word) -> \(candidate); scores: \(scoreOriginal) vs \(scoreCandidate); threshold=\(threshold)")

        guard AutoFixDecision.shouldReplace(scoreOriginal: scoreOriginal, scoreCandidate: scoreCandidate, threshold: threshold) else {
            logSkip(.belowThreshold, word: word, bundleID: bundleID, extra: [
                "score_original": .double(scoreOriginal),
                "score_candidate": .double(scoreCandidate),
                "algorithm": .string(algorithm.rawValue),
                "from_lang": .string(currentLang),
                "to_lang": .string(targetLang)
            ])
            return
        }

        applyFix(
            original: word,
            candidate: candidate,
            boundary: boundary,
            fromLayoutID: currentID,
            targetLayoutID: targetID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID
        )
    }

    private func applyFix(
        original: String,
        candidate: String,
        boundary: String,
        fromLayoutID: String,
        targetLayoutID: String,
        scoreOriginal: Double,
        scoreCandidate: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        bundleID: String
    ) {
        AppLogger.action(logger, "Auto-fix applying: \(original) -> \(candidate)")
        // Word + boundary char already typed. Delete the original word and the
        // boundary, then re-type the candidate followed by the same boundary so
        // Enter/Tab keep their semantics (newline, focus shift, indent).
        let boundaryToReplay = boundary.isEmpty ? " " : boundary
        let totalToDelete = original.count + boundaryToReplay.count
        deleteCharacters(count: totalToDelete)
        typeText(candidate + boundaryToReplay)
        layoutManager.switchTo(targetLayoutID)

        lastFix = PendingUndo(
            original: original,
            replacement: candidate,
            boundary: boundaryToReplay,
            fromLayoutID: fromLayoutID,
            timestamp: ProcessInfo.processInfo.systemUptime
        )

        AnalyticsCounters.recordReplacement(text: candidate)
        NotificationCenter.default.post(name: .textReplacementDidComplete, object: nil)

        if Defaults[.autoFixToastEnabled] {
            let cursor = NSEvent.mouseLocation
            FixToastCoordinator.shared.show(near: cursor) { [weak self] in
                self?.undoAndAddToAllowlist()
            }
        }

        PapugaEventLog.shared.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixApplied,
            frontmostBundleID: bundleID,
            inputLayout: targetLayoutID,
            properties: [
                "original_length": .int(original.count),
                "replacement_length": .int(candidate.count),
                "score_original": .double(scoreOriginal),
                "score_candidate": .double(scoreCandidate),
                "algorithm": .string(algorithm.rawValue),
                "from_lang": .string(currentLang),
                "to_lang": .string(targetLang)
            ]
        ))

        ReplacementHistoryStore.shared.record(
            ReplacementHistoryEntry(
                kind: .autoFixApplied,
                original: original,
                converted: candidate,
                sourceLayoutID: fromLayoutID,
                targetLayoutID: targetLayoutID,
                bundleID: bundleID
            )
        )
    }

    private func applyCustomRule(
        rule: CustomAutoReplaceRule,
        original: String,
        boundary: String,
        bundleID: String
    ) {
        AppLogger.action(logger, "Custom rule applying: \(rule.source) -> \(rule.target)")
        let fromLayoutID = layoutManager.getCurrentLayoutID()
        let boundaryToReplay = boundary.isEmpty ? " " : boundary
        let totalToDelete = original.count + boundaryToReplay.count
        deleteCharacters(count: totalToDelete)
        typeText(rule.target + boundaryToReplay)

        lastFix = PendingUndo(
            original: original,
            replacement: rule.target,
            boundary: boundaryToReplay,
            fromLayoutID: fromLayoutID,
            timestamp: ProcessInfo.processInfo.systemUptime
        )

        AnalyticsCounters.recordReplacement(text: rule.target)
        NotificationCenter.default.post(name: .textReplacementDidComplete, object: nil)

        if Defaults[.autoFixToastEnabled] {
            let cursor = NSEvent.mouseLocation
            FixToastCoordinator.shared.show(near: cursor) { [weak self] in
                self?.undoAndAddToAllowlist()
            }
        }

        PapugaEventLog.shared.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixApplied,
            frontmostBundleID: bundleID,
            inputLayout: fromLayoutID,
            properties: [
                "original_length": .int(original.count),
                "replacement_length": .int(rule.target.count),
                "rule_origin": .string(rule.createdFromRecommendation ? "recommendation" : "manual"),
                "source": .string("custom_rule")
            ]
        ))

        ReplacementHistoryStore.shared.record(
            ReplacementHistoryEntry(
                kind: .autoFixApplied,
                original: original,
                converted: rule.target,
                sourceLayoutID: fromLayoutID,
                targetLayoutID: nil,
                bundleID: bundleID
            )
        )
    }

    private func logSkip(
        _ reason: AutoFixSkipReason,
        word: String,
        bundleID: String,
        extra: [String: AnalyticsValue] = [:]
    ) {
        AppLogger.post(logger, "auto-fix skipped: reason=\(reason.rawValue) word=\(word)")
        var props: [String: AnalyticsValue] = [
            "reason": .string(reason.rawValue),
            "word_length": .int(word.count)
        ]
        for (k, v) in extra { props[k] = v }
        PapugaEventLog.shared.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixSkipped,
            frontmostBundleID: bundleID,
            inputLayout: layoutManager.getCurrentLayoutID(),
            properties: props
        ))
    }

    private func deleteCharacters(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Delete), keyDown: true)
            down?.post(tap: .cgAnnotatedSessionEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Delete), keyDown: false)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var unit = UniChar(scalar.value & 0xFFFF)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down?.post(tap: .cgAnnotatedSessionEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func isResetKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Escape, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return true
        default:
            return false
        }
    }

    private func isWordBoundary(keyCode: UInt16, typedString: String) -> Bool {
        AutoFixDecision.isWordBoundary(keyCode: keyCode, typedString: typedString)
    }

    private func languageHintForLayoutID(_ layoutID: String) -> String {
        AutoFixDecision.languageHintForLayoutID(layoutID)
    }
}

private struct WordBuffer {
    private(set) var text = ""
    private(set) var keyCodes: [UInt16] = []

    mutating func append(string: String, keyCode: UInt16) {
        text.append(string)
        keyCodes.append(keyCode)
    }

    mutating func popLast() {
        guard !text.isEmpty else { return }
        text.removeLast()
        if !keyCodes.isEmpty { keyCodes.removeLast() }
    }

    mutating func reset() {
        text = ""
        keyCodes.removeAll()
    }
}

private struct PendingUndo {
    let original: String
    let replacement: String
    let boundary: String
    let fromLayoutID: String
    let timestamp: TimeInterval
}

private func autoFixCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let controller = Unmanaged<AutoFixController>.fromOpaque(userInfo).takeUnretainedValue()
    controller.handleEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
