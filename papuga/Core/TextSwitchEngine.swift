import Foundation
import Defaults

final class TextSwitchEngine {
    private let clipboardManager = ClipboardManager()
    private let characterMapper = CharacterMapper()
    private let layoutManager: LayoutManager
    private let clipboardHistoryManager: ClipboardHistoryManager?
    private let logger = AppLogger.switchEngine

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
        guard clipboardManager.hasSelectedTextInFocusedElement() else {
            AppLogger.warn(logger, "[\(operationID)] Aborted: no selected text in focused element")
            return
        }

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
            }

            AppLogger.action(logger, "[\(operationID)] Waiting for clipboard update")
            try? await Task.sleep(for: .seconds(Constants.clipboardWaitDuration))

            let text = await getTextWithRetry(previousChangeCount: changeCountBefore, operationID: operationID)

            guard let text, !text.isEmpty else {
                AppLogger.warn(logger, "[\(operationID)] Aborted: copied text is empty")
                clipboardManager.restore(savedState)
                AppLogger.post(logger, "[\(operationID)] Clipboard restored after empty text")
                return
            }
            AppLogger.post(logger, "[\(operationID)] Text captured (\(text.count) chars)")

            let currentID = layoutManager.getCurrentLayoutID()
            AppLogger.action(logger, "[\(operationID)] Current layout id: \(currentID)")

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

            AppLogger.action(logger, "[\(operationID)] Writing converted text to clipboard")
            clipboardManager.setText(converted)

            let resultMode = SwitchResultMode(rawValue: Defaults[.switchResultMode]) ?? .copyAndPaste
            if resultMode == .copyAndPaste {
                AppLogger.action(logger, "[\(operationID)] Simulating paste")
                clipboardManager.simulatePaste()
            } else {
                AppLogger.action(logger, "[\(operationID)] Paste skipped: copy-only mode")
            }

            updateAnalytics(text: text, operationID: operationID)
            AppLogger.action(logger, "[\(operationID)] Emitting textReplacementDidComplete notification")
            NotificationCenter.default.post(name: .textReplacementDidComplete, object: nil)

            try? await Task.sleep(for: .seconds(Constants.clipboardWaitDuration))
            AppLogger.action(logger, "[\(operationID)] Switching system layout to target")
            layoutManager.switchTo(targetID)
            AppLogger.post(logger, "[\(operationID)] System layout switched")

            try? await Task.sleep(for: .seconds(Constants.clipboardRestoreDelay))
            AppLogger.action(logger, "[\(operationID)] Restoring original clipboard state")
            clipboardManager.restore(savedState)
            AppLogger.post(logger, "[\(operationID)] Switch flow completed")
        }
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
        AppLogger.warn(logger, "[\(operationID)] Clipboard did not change after retries, reading current value")
        let fallbackText = clipboardManager.getText()
        AppLogger.post(logger, "[\(operationID)] getTextWithRetry completed with fallback value")
        return fallbackText
    }

    private func updateAnalytics(text: String, operationID: String) {
        AppLogger.pre(logger, "[\(operationID)] updateAnalytics()")

        let wordsInText = max(1, text.split(separator: " ").count)
        let savedSecondsForCurrentText = Int((Double(wordsInText) * Constants.estimatedManualReplacementSecondsPerWord).rounded())
        let updatedReplacementCount = Defaults[.textReplacementCount] + 1
        let updatedWordsTotal = Defaults[.totalReplacedWords] + wordsInText

        let currentDay = currentDayStamp()
        if Defaults[.analyticsDayStamp] != currentDay {
            Defaults[.analyticsDayStamp] = currentDay
            Defaults[.savedSecondsToday] = 0
            AppLogger.action(logger, "[\(operationID)] Analytics day changed -> reset today counter for \(currentDay)")
        }

        let updatedSavedSecondsToday = Defaults[.savedSecondsToday] + savedSecondsForCurrentText

        Defaults[.textReplacementCount] = updatedReplacementCount
        Defaults[.totalReplacedWords] = updatedWordsTotal
        Defaults[.savedSecondsToday] = updatedSavedSecondsToday

        AppLogger.post(
            logger,
            "[\(operationID)] Analytics updated: replacements=\(updatedReplacementCount), wordsTotal=\(updatedWordsTotal), wordsInCurrentText=\(wordsInText), savedSecondsCurrent=\(savedSecondsForCurrentText), savedSecondsToday=\(updatedSavedSecondsToday)"
        )
    }

    private func currentDayStamp() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
