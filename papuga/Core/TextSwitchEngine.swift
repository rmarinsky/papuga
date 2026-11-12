import Foundation
import Defaults

final class TextSwitchEngine {
    private let clipboardManager = ClipboardManager()
    private let characterMapper = CharacterMapper()
    private let layoutManager: LayoutManager
    private let clipboardHistoryManager: ClipboardHistoryManager?
    private let logger = AppLogger.switchEngine
    /// A switch in flight. Both entry points run on the main thread — `HotkeyListener`
    /// installs its tap source on `CFRunLoopGetMain()`, and `KeyboardShortcuts` delivers
    /// on main — so a plain flag is enough to serialize them.
    private var isSwitching = false

    init(layoutManager: LayoutManager, clipboardHistoryManager: ClipboardHistoryManager? = nil) {
        AppLogger.pre(logger, "init(layoutManager:)")
        self.layoutManager = layoutManager
        self.clipboardHistoryManager = clipboardHistoryManager
        AppLogger.post(logger, "TextSwitchEngine initialized")
    }

    func performSwitch(direction: SwitchDirection) {
        let operationID = UUID().uuidString
        AppLogger.pre(logger, "[\(operationID)] performSwitch(direction: \(String(describing: direction)))")

        guard Defaults[.isServiceRunning] else {
            AppLogger.warn(logger, "[\(operationID)] Aborted: service is disabled")
            return
        }
        // A second trigger mid-flight would snapshot the *converted* text as the
        // "original" clipboard and paste that back once the first run restores.
        guard !isSwitching else {
            AppLogger.warn(logger, "[\(operationID)] Aborted: a switch is already in flight")
            return
        }
        isSwitching = true
        let historyManager = clipboardHistoryManager
        historyManager?.suspendTracking(reason: "textSwitch:\(operationID)")
        AppLogger.action(logger, "[\(operationID)] Saving clipboard state")
        let savedState = clipboardManager.save()
        let changeCountBefore = clipboardManager.changeCount

        AppLogger.action(logger, "[\(operationID)] Simulating copy")
        clipboardManager.simulateCopy()

        Task { @MainActor in
            defer {
                historyManager?.resumeTracking(reason: "textSwitch:\(operationID)")
                isSwitching = false
            }

            // No fixed pre-read delay: getTextWithRetry polls changeCount with early-exit, so a
            // fast app's clipboard is read the moment it updates instead of always paying the pad.
            let text = await getTextWithRetry(previousChangeCount: changeCountBefore, operationID: operationID)

            guard let text, !text.isEmpty else {
                AppLogger.warn(logger, "[\(operationID)] Aborted: copied text is unavailable or empty")
                clipboardManager.restore(savedState)
                AppLogger.post(logger, "[\(operationID)] Clipboard restored after failed text capture")
                return
            }
            AppLogger.post(logger, "[\(operationID)] Text captured (\(text.count) chars)")

            // The text says which layout it was typed in; the system layout only
            // says where the keyboard is now. They differ whenever the layout was
            // switched (by hand or by AutoFix) after the text was typed, and then
            // converting "from the current layout" maps the text the wrong way.
            let systemID = layoutManager.getCurrentLayoutID()
            let orderedIDs = layoutManager.orderedLayouts()
            for id in orderedIDs {
                if let source = layoutManager.sourceForID(id) { characterMapper.buildMap(for: source, sourceID: id) }
            }
            let currentID = Self.sourceLayout(of: text, among: orderedIDs, systemLayoutID: systemID) { character, id in
                self.characterMapper.mapping(for: character, sourceID: id) != nil
            }
            AppLogger.action(logger, "[\(operationID)] Source layout id: \(currentID) (system: \(systemID))")

            guard let targetID = layoutManager.nextLayout(after: currentID, direction: direction) else {
                AppLogger.warn(logger, "[\(operationID)] Aborted: unable to resolve target layout")
                clipboardManager.restore(savedState)
                AppLogger.post(logger, "[\(operationID)] Clipboard restored after missing target layout")
                return
            }
            AppLogger.post(logger, "[\(operationID)] Target layout id: \(targetID)")

            guard let currentSource = layoutManager.sourceForID(currentID),
                  let targetSource = layoutManager.sourceForID(targetID) else {
                AppLogger.warn(logger, "[\(operationID)] Aborted: missing layout sources")
                clipboardManager.restore(savedState)
                AppLogger.post(logger, "[\(operationID)] Clipboard restored after missing layout source")
                return
            }

            AppLogger.action(logger, "[\(operationID)] Building character maps")
            characterMapper.buildMap(for: currentSource, sourceID: currentID)
            characterMapper.buildMap(for: targetSource, sourceID: targetID)

            let converted = characterMapper.convert(text: text, fromSourceID: currentID, toSourceID: targetID)
            AppLogger.post(logger, "[\(operationID)] Conversion completed (\(converted.count) chars)")

            let learningSnapshot = ManualReplacementSnapshot.capture(original: text)
            AppLogger.action(logger, "[\(operationID)] Writing converted text to clipboard")
            clipboardManager.setText(converted)

            let resultMode = SwitchResultMode(rawValue: Defaults[.switchResultMode]) ?? .copyAndPaste
            if resultMode == .copyAndPaste {
                AppLogger.action(logger, "[\(operationID)] Simulating paste")
                clipboardManager.simulatePaste()
            } else {
                AppLogger.action(logger, "[\(operationID)] Paste skipped: copy-only mode")
            }

            try? await Task.sleep(for: .seconds(Constants.switchLayoutSettleDelay))
            let verified = resultMode == .copyAndPaste && learningSnapshot?.confirms(replacement: converted) == true
            updateAnalytics(text: text, operationID: operationID)
            ReplacementHistoryStore.shared.record(
                ReplacementHistoryEntry(
                    kind: .manualSwitch,
                    original: text,
                    converted: converted,
                    sourceLayoutID: currentID,
                    targetLayoutID: targetID,
                    bundleID: AppContextProvider.frontmostBundleID(),
                    verificationSucceeded: verified
                )
            )
            AppLogger.action(logger, "[\(operationID)] Emitting textReplacementDidComplete notification")
            NotificationCenter.default.post(name: .textReplacementDidComplete, object: nil)

            AppLogger.action(logger, "[\(operationID)] Switching system layout to target")
            layoutManager.switchTo(targetID)
            AppLogger.post(logger, "[\(operationID)] System layout switched")

            try? await Task.sleep(for: .seconds(Constants.clipboardRestoreDelay))
            AppLogger.action(logger, "[\(operationID)] Restoring original clipboard state")
            clipboardManager.restore(savedState)
            AppLogger.post(logger, "[\(operationID)] Switch flow completed")
        }
    }

    /// The layout that can type the most letters of `text`. The system layout
    /// wins ties, so same-script layouts and letterless text behave as before.
    static func sourceLayout(
        of text: String,
        among layoutIDs: [String],
        systemLayoutID: String,
        canType: (Character, String) -> Bool
    ) -> String {
        let letters = text.filter(\.isLetter)
        func coverage(_ id: String) -> Int { letters.filter { canType($0, id) }.count }
        let systemCoverage = coverage(systemLayoutID)
        let best = layoutIDs.filter { $0 != systemLayoutID }
            .map { (id: $0, coverage: coverage($0)) }
            .max { $0.coverage < $1.coverage }
        guard let best, best.coverage > systemCoverage else { return systemLayoutID }
        return best.id
    }

    func invalidateMaps() {
        AppLogger.pre(logger, "invalidateMaps()")
        characterMapper.invalidateCache()
        AppLogger.post(logger, "Character maps invalidated")
    }

    private func getTextWithRetry(previousChangeCount: Int, operationID: String) async -> String? {
        AppLogger.pre(logger, "[\(operationID)] getTextWithRetry(previousChangeCount: \(previousChangeCount))")
        for i in 0..<Constants.clipboardRetryCount {
            AppLogger.action(logger, "[\(operationID)] Clipboard retry attempt \(i + 1)/\(Constants.clipboardRetryCount)")
            if clipboardManager.changeCount != previousChangeCount {
                let text = clipboardManager.getText()
                AppLogger.post(logger, "[\(operationID)] Clipboard changed on attempt \(i + 1)")
                return text
            }
            if i < Constants.clipboardRetryCount - 1 {
                try? await Task.sleep(for: .seconds(Constants.clipboardRetryInterval))
            }
        }
        AppLogger.warn(logger, "[\(operationID)] Clipboard did not change after retries; copy likely failed or no text is selected")
        return nil
    }

    private func updateAnalytics(text: String, operationID: String) {
        AppLogger.pre(logger, "[\(operationID)] updateAnalytics()")
        AnalyticsCounters.recordReplacement(text: text)
        AppLogger.post(
            logger,
            "[\(operationID)] Analytics updated: replacements=\(Defaults[.textReplacementCount]), wordsTotal=\(Defaults[.totalReplacedWords]), savedSecondsToday=\(Defaults[.savedSecondsToday])"
        )
    }

}
