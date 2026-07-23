import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Defaults
import Foundation
import os

enum PapugaSyntheticEvent {
    private static let marker: Int64 = 0x504150554741

    static func tag(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func isTagged(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}

@MainActor
final class AutoFixController {
    private let layoutManager: LayoutManager
    private let characterMapper: CharacterMapper
    private let logger = AppLogger.autoFix

    /// The event tap runs on its own high-priority thread (not the main run loop) so its callback
    /// is never starved by main-thread UI work — which would delay keystroke pass-through to the
    /// frontmost app and risk the window server disabling the tap (tapDisabledByTimeout).
    /// `let` so the nonisolated tap callback can reach it without an actor hop / data race.
    private let eventTapRunner = AutoFixEventTap(mask: AutoFixController.eventMask)

    private static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.flagsChanged.rawValue) |
        (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.rightMouseDown.rawValue)

    private var buffer = WordBuffer()
    private var lastFix: PendingUndo?
    private var pendingProposalRecovery: PendingProposalRecovery?
    private var pendingReapply: PendingReapply?
    private var editingGuard = AutoFixEditingGuard()
    private var layoutIncident = LayoutIncidentTracker()
    private var layoutIncidentContext: LayoutIncidentContext?
    private var pendingSingleDecision: DeferredSingleDecision?
    private var isCapturingLayoutIncident = false
    private var layoutIncidentTimerState = LayoutIncidentTimerState()
    private var layoutIncidentTimerTask: Task<Void, Never>?
    private let mistakeEngine: MistakeObservationEngine
    private let spellChecker: SpellCheckingClient
    private let decisionHistory: AutoFixDecisionRecording
    private var activeDecisionDraft: AutoFixDecisionDraft?
    private let manualCorrectionTracker = ManualCorrectionTracker()
    private let targetValidator = AutoFixTargetValidator()
    private var appActivationObserver: NSObjectProtocol?
    private var consecutiveReplacementDirection: AutoFixReplacementDirection?
    /// Cached language scorer, reused across word boundaries (rebuilt only if the algorithm
    /// changes). Avoids per-word scorer/NLLanguageRecognizer allocation. Safe: only touched on the
    /// main actor inside evaluateAndMaybeFix.
    private var cachedScorer: (algorithm: LanguageScorerAlgorithm, scorer: LanguageScorer)?
    /// Reused for synthetic delete/type keystroke bursts instead of allocating a CGEventSource per
    /// fix/undo. Only used on the main actor.
    /// Cached copy of the Defaults-backed rule list. Avoids a JSON decode on every word boundary;
    /// kept in sync via a Defaults observer so AISuggestionApplier writes are also captured.
    private var cachedCustomRules: [CustomAutoReplaceRule] = Defaults[.customAutoReplaceRules]
    private var customRulesObservation: Defaults.Observation?

    init(
        layoutManager: LayoutManager,
        characterMapper: CharacterMapper,
        mistakeEngine: MistakeObservationEngine = .shared,
        spellChecker: SpellCheckingClient = SystemSpellCheckingClient(),
        decisionHistory: AutoFixDecisionRecording = AutoFixDecisionHistoryStore.shared
    ) {
        self.layoutManager = layoutManager
        self.characterMapper = characterMapper
        self.mistakeEngine = mistakeEngine
        self.spellChecker = spellChecker
        self.decisionHistory = decisionHistory
    }

    func start() {
        AppLogger.pre(logger, "AutoFixController.start()")
        guard !eventTapRunner.isActive else {
            AppLogger.warn(logger, "start() skipped: tap already active")
            return
        }

        // Pass an unretained pointer to self; the controller outlives the tap (app lifetime) and
        // stop() tears the tap down before deinit.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard eventTapRunner.start(userInfo: userInfo, callback: autoFixCallback) else {
            AppLogger.error(logger, "CGEvent.tapCreate failed for AutoFixController")
            return
        }

        installAppActivationObserverIfNeeded()
        installCustomRulesObservationIfNeeded()
        AppLogger.post(logger, "AutoFixController tap attached (dedicated thread)")
    }

    func stop() {
        AppLogger.pre(logger, "AutoFixController.stop()")
        eventTapRunner.stop()
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        resetTypingState(clearLastFix: true)
        AppLogger.post(logger, "AutoFixController stopped")
    }

    /// Undo the most recent auto-fix on demand (e.g. from a global shortcut),
    /// if one is still pending. Restores the original word and layout.
    func undoLastFix() {
        guard let pending = lastFix else {
            AppLogger.post(logger, "undoLastFix() ignored: no pending fix")
            return
        }
        if let reapply = undo(pending) {
            showReapplyRecovery(reapply)
        }
        lastFix = nil
    }

    private func installCustomRulesObservationIfNeeded() {
        guard customRulesObservation == nil else { return }
        customRulesObservation = Defaults.observe(.customAutoReplaceRules) { [weak self] change in
            Task { @MainActor [weak self] in
                self?.cachedCustomRules = change.newValue
            }
        }
    }

    private func installAppActivationObserverIfNeeded() {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetTypingState(clearLastFix: false)
            }
        }
    }

    private func resetTypingState(clearLastFix: Bool) {
        AutoFixProposalCoordinator.shared.dismiss()
        clearRecovery()
        buffer.reset()
        if clearLastFix {
            lastFix = nil
        }
        editingGuard.reset()
        resetLayoutIncident()
        manualCorrectionTracker.resetEditingState()
        targetValidator.reset()
        consecutiveReplacementDirection = nil
    }

    fileprivate nonisolated func handleEvent(type: CGEventType, event: CGEvent) {
        if PapugaSyntheticEvent.isTagged(event) {
            return
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Runs on the tap thread; re-enable directly (eventTapRunner is a thread-safe `let`).
            eventTapRunner.reEnable()
            return
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let timestamp = ProcessInfo.processInfo.systemUptime
        let typedString = readTypedString(from: event)
        let targetPID = AutoFixTargetValidator.targetPID(from: event)

        DispatchQueue.main.async { [weak self] in
            self?.processEvent(
                type: type,
                targetPID: targetPID,
                keyCode: keyCode,
                flags: flags,
                typedString: typedString,
                timestamp: timestamp
            )
        }
    }

    fileprivate nonisolated func handleProposalShortcutSynchronously(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown else { return false }

        // Fast path read directly on the tap thread — no main-thread hop. When no proposal is on
        // screen (the overwhelmingly common case) this returns immediately. The gate mirrors the
        // panel's visibility, set/cleared on the main actor in the coordinator's show/dismiss.
        guard AutoFixProposalShortcutGate.shared.isArmed else { return false }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Mirror AutoFixProposalCoordinator.handleKeyboardShortcut's matching so we can decide to
        // swallow synchronously without blocking the tap thread on the main run loop.
        guard !flags.contains(.maskCommand),
              !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else {
            return false
        }
        switch keyCode {
        case 0x24, 0x4C, 0x35: // Return, keypad Enter, Escape
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = AutoFixProposalCoordinator.shared.handleKeyboardShortcut(keyCode: keyCode, flags: flags)
                }
            }
            return true
        default:
            return false
        }
    }

    private nonisolated func readTypedString(from event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: chars, count: length)
    }

    private func processEvent(
        type: CGEventType,
        targetPID: pid_t?,
        keyCode: UInt16,
        flags: CGEventFlags,
        typedString: String,
        timestamp: TimeInterval
    ) {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            // If the click is on our undo toast, let SwiftUI's Button handle it.
            // Resetting lastFix here would null out the pending undo before the
            // Button action can fire, defeating the toast.
            if FixToastCoordinator.shared.isMouseOverToast()
                || AutoFixProposalCoordinator.shared.isMouseOverProposal() {
                return
            }
            resetTypingState(clearLastFix: true)
            // A click may land inside existing text, so suppress the very next word. We use
            // noteClickSuppression (not noteEditingStarted) so auto-fix resumes normally for every
            // word after that first one — typing a whole fresh word after clicking is safe.
            if Defaults[.autoFixConservativeEditingGuard] {
                editingGuard.noteClickSuppression()
            }
            return
        case .keyDown:
            break
        default:
            return
        }

        AutoFixProposalCoordinator.shared.dismiss(outcome: .dismissed)
        clearRecovery()

        let isBoundary = isWordBoundary(keyCode: keyCode, typedString: typedString)
        if type == .keyDown,
           !typedString.isEmpty,
           !isBoundary {
            notePrintableContinuation(timestamp: timestamp)
        }

        if flags.contains(.maskCommand) {
            resetTypingState(clearLastFix: true)
            return
        }

        if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            handleBackspace(timestamp: timestamp)
            return
        }

        if isResetKey(keyCode) {
            resetTypingState(clearLastFix: true)
            editingGuard.noteResetKey(keyCode, enabled: Defaults[.autoFixConservativeEditingGuard])
            return
        }

        if isBoundary {
            let wordWasEmpty = buffer.text.isEmpty
            evaluateAndMaybeFix(boundary: typedString)
            editingGuard.noteBoundary(bufferWasEmpty: wordWasEmpty, isNewline: Int(keyCode) == kVK_Return)
            buffer.reset()
            targetValidator.reset()
            return
        }

        if !typedString.isEmpty {
            if buffer.text.isEmpty {
                targetValidator.startSession(targetPID: targetPID, keyCode: keyCode, typedString: typedString)
            } else {
                let validation = targetValidator.validateKeyEventStillTargetsSession(targetPID: targetPID)
                if case .changed = validation {
                    logSkip(.targetChanged, word: buffer.text, bundleID: AppContextProvider.frontmostBundleID() ?? "")
                    resetTypingState(clearLastFix: false)
                    targetValidator.startSession(targetPID: targetPID, keyCode: keyCode, typedString: typedString)
                }
            }
            buffer.append(string: typedString, keyCode: keyCode)
        }
    }

    private func handleBackspace(timestamp: TimeInterval) {
        let bufferWasEmpty = buffer.text.isEmpty
        // The tap observes Backspace after the target editor has already consumed it. Using that
        // key as an undo gesture would therefore delete the untouched Space/Return/Tab boundary
        // before Papuga can validate anything. Undo remains available through the range-safe chip.
        lastFix = nil
        manualCorrectionTracker.noteBackspace(bufferWasEmpty: bufferWasEmpty, timestamp: timestamp)
        editingGuard.noteBackspace(bufferWasEmpty: bufferWasEmpty, enabled: Defaults[.autoFixConservativeEditingGuard])
        resetLayoutIncident()
        buffer.popLast()
        if buffer.text.isEmpty {
            targetValidator.reset()
        }
    }

    private func undoFromToast() {
        guard let pending = lastFix else { return }
        if let reapply = undo(pending) {
            showReapplyRecovery(reapply)
        }
        lastFix = nil
    }

    private func undo(_ pending: PendingUndo) -> PendingReapply? {
        let bundleID = AppContextProvider.frontmostBundleID() ?? ""
        guard let replacementResult = targetValidator.replaceAnchoredText(
            pending.replacementAnchor,
            with: pending.original
        ) else {
            recordMutationFailure(
                source: pending.replacement,
                candidate: pending.original,
                fromLayoutID: pending.targetLayoutID,
                targetLayoutID: pending.fromLayoutID,
                bundleID: bundleID,
                scope: pending.replacement.contains(where: \.isWhitespace) ? .phrase : .word
            )
            return nil
        }
        AppLogger.action(logger, "Undoing recent auto-fix: \(pending.replacement) -> \(pending.original)")
        let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - pending.timestamp) * 1000)
        if pending.changesInputLayout {
            layoutManager.switchTo(pending.fromLayoutID)
        }
        AnalyticsCounters.reverseReplacement(text: pending.replacement)

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
        guard let restoredAnchor = replacementResult.recoveryAnchor else { return nil }
        return PendingReapply(
            original: pending.original,
            replacement: pending.replacement,
            fromLayoutID: pending.fromLayoutID,
            targetLayoutID: pending.targetLayoutID,
            changesInputLayout: pending.changesInputLayout,
            replacementAnchor: restoredAnchor,
            expiresAt: ProcessInfo.processInfo.systemUptime + 10
        )
    }

    private func resolvedScorer(for algorithm: LanguageScorerAlgorithm) -> LanguageScorer {
        if let cached = cachedScorer, cached.algorithm == algorithm {
            return cached.scorer
        }
        let scorer = LanguageScorerFactory.make(algorithm)
        cachedScorer = (algorithm, scorer)
        return scorer
    }

    private func evaluateAndMaybeFix(boundary: String) {
        let word = buffer.text
        guard !word.isEmpty else {
            // Boundary fired with nothing typed: the latch is cleared by noteBoundary in the caller.
            return
        }

        let bundleID = AppContextProvider.frontmostBundleID() ?? ""
        let currentID = layoutManager.getCurrentLayoutID()
        let currentLang = languageHintForLayoutID(currentID)
        let configuredAlgorithm = (
            LanguageScorerAlgorithm(rawValue: Defaults[.autoFixAlgorithm]) ?? .appleNL
        ).resolvedImplementation
        beginDecision(
            source: word,
            sourceLayoutID: currentID,
            sourceLanguage: currentLang,
            bundleID: bundleID,
            algorithm: configuredAlgorithm
        )
        defer { finishDecision() }
        let targetSession = targetValidator.session
        let targetValidation = targetValidator.validateCurrentTarget(expectedBundleID: bundleID)
        if case .changed(let reason) = targetValidation {
            logSkip(.targetChanged, word: word, bundleID: bundleID, extra: [
                "target_reason": .string(reason),
                "from_lang": .string(currentLang)
            ])
            resetLayoutIncident()
            return
        }

        let appPolicy = AutoFixAppPolicyResolver.policy(for: bundleID)
        guard appPolicy != .disabled else {
            logSkip(.unsafeEditor, word: word, bundleID: bundleID, extra: [
                "app_policy": .string(appPolicy.rawValue)
            ])
            resetLayoutIncident()
            return
        }
        let canMutateDirectly = targetValidation.canMutate && appPolicy.allowsAutomaticMutation

        if let correction = manualCorrectionTracker.noteCompletedWord(
            word,
            language: currentLang,
            bundleID: bundleID.isEmpty ? nil : bundleID,
            timestamp: ProcessInfo.processInfo.systemUptime
        ) {
            mistakeEngine.recordManualCorrection(correction)
        }

        if editingGuard.shouldSuppress(enabled: Defaults[.autoFixConservativeEditingGuard]) {
            logSkip(.editingContext, word: word, bundleID: bundleID, extra: [
                "from_lang": .string(currentLang)
            ])
            resetLayoutIncident()
            return
        }

        if Defaults[.autoFixBlocklist].contains(bundleID) {
            logSkip(.blocklist, word: word, bundleID: bundleID)
            resetLayoutIncident()
            return
        }

        // An explicit “Never replace” choice must override every mutation source,
        // including an older custom rule for the same word.
        if AutoFixDecision.isInAllowlist(word, allowlist: Defaults[.autoFixAllowlist]) {
            logSkip(.allowlist, word: word, bundleID: bundleID)
            resetLayoutIncident()
            return
        }

        if let rule = cachedCustomRules.first(where: { $0.matches(word) }) {
            resetLayoutIncident()
            if canMutateDirectly {
                applyCustomRule(
                    rule: rule,
                    original: word,
                    boundary: boundary,
                    bundleID: bundleID,
                    targetSession: targetSession
                )
            } else if appPolicy.allowsProposal {
                showRuleProposal(
                    rule: rule,
                    original: word,
                    boundary: boundary,
                    fromLayoutID: currentID,
                    bundleID: bundleID,
                    targetSession: targetSession
                )
            } else {
                logSkip(.unsafeEditor, word: word, bundleID: bundleID)
            }
            return
        }

        if let protectedMatch = ProtectedLexiconStore.shared.match(word),
           protectedMatch.protectsSource {
            logSkip(.mixedLanguageIntentional, word: word, bundleID: bundleID, extra: [
                "token_kind": .string(String(describing: AutoFixTokenClassifier.classify(word))),
                "lexicon_entry_id": .string(protectedMatch.entry.id),
                "lexicon_source": .string(protectedMatch.entry.source),
                "from_lang": .string(currentLang)
            ])
            resetLayoutIncident()
            return
        }

        let skipReason = AutoFixDecision.shouldSkipWord(word, minLength: Defaults[.autoFixMinWordLength])
        if let skip = skipReason {
            switch skip {
            case .tooShort:
                break
            case .containsDigits, .containsForbiddenChars:
                logSkip(.containsDigits, word: word, bundleID: bundleID)
                resetLayoutIncident()
                return
            }
        }
        let candidateTargetIDs = layoutManager.candidateTargets(excluding: currentID)
        guard !candidateTargetIDs.isEmpty else {
            logSkip(.noTargetLayout, word: word, bundleID: bundleID)
            observeMistakeCandidate(word: word, language: currentLang, bundleID: bundleID)
            resetLayoutIncident()
            return
        }
        guard let currentSrc = layoutManager.sourceForID(currentID) else {
            logSkip(.missingMaps, word: word, bundleID: bundleID)
            observeMistakeCandidate(word: word, language: currentLang, bundleID: bundleID)
            resetLayoutIncident()
            return
        }
        characterMapper.buildMap(for: currentSrc, sourceID: currentID)

        let algorithm = configuredAlgorithm
        let scorer = resolvedScorer(for: algorithm)
        let threshold = Defaults[.autoFixThreshold]
        let scoreOriginal = scorer.score(word, expecting: currentLang)

        // Evaluate EVERY configured layout, not just the next one in the cycle, and let the language
        // scorer decide which target is correct. This fixes wrong-direction conversions when 3+
        // layouts are configured (e.g. US + Ukrainian + Russian), where "next in cycle" is often
        // the wrong language.
        var evaluatedCandidates: [AutoFixTargetCandidate] = []
        for candidateTargetID in candidateTargetIDs {
            guard let candidateSrc = layoutManager.sourceForID(candidateTargetID) else { continue }
            characterMapper.buildMap(for: candidateSrc, sourceID: candidateTargetID)
            let mapped = characterMapper.convert(text: word, fromSourceID: currentID, toSourceID: candidateTargetID)
            guard mapped != word else { continue }
            let mappedLang = languageHintForLayoutID(candidateTargetID)
            let mappedScore = scorer.score(mapped, expecting: mappedLang)
            evaluatedCandidates.append(AutoFixTargetCandidate(
                targetID: candidateTargetID,
                targetLang: mappedLang,
                candidate: mapped,
                scoreCandidate: mappedScore
            ))
        }

        updateDecisionCandidates(
            scoreOriginal: scoreOriginal,
            candidates: evaluatedCandidates,
            threshold: threshold
        )

        guard let selection = AutoFixCandidateGenerator.select(
            candidates: evaluatedCandidates,
            scoreOriginal: scoreOriginal,
            threshold: threshold,
            separation: Defaults[.autoFixCandidateSeparation]
        ) else {
            logSkip(.identicalCandidate, word: word, bundleID: bundleID, layoutID: currentID)
            observeMistakeCandidate(word: word, language: currentLang, bundleID: bundleID)
            resetLayoutIncident()
            return
        }

        let targetID = selection.best.targetID
        let targetLang = selection.best.targetLang
        let candidate = selection.best.candidate
        let scoreCandidate = selection.best.scoreCandidate
        let isAmbiguousTarget = selection.isAmbiguous
        selectDecisionCandidate(selection.best)

        if skipReason == .tooShort {
            logSkip(.tooShort, word: word, bundleID: bundleID, layoutID: currentID)
            _ = handleLayoutIncidentToken(
                original: word,
                candidate: candidate,
                boundary: boundary,
                fromLayoutID: currentID,
                targetLayoutID: targetID,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: threshold,
                algorithm: algorithm,
                currentLang: currentLang,
                targetLang: targetLang,
                bundleID: bundleID,
                canMutateDirectly: canMutateDirectly,
                allowsProposal: appPolicy.allowsProposal,
                targetSession: targetSession,
                evidence: .neutral,
                singleAction: .none
            )
            return
        }

        // Hard guard against false positives like `faster` -> `афіеук`. If the
        // original is a real word in the current layout's language, the user
        // intended to type it; never replace.
        if !spellChecker.isMisspelled(word, language: currentLang) {
            logSkip(.originalIsRealWord, word: word, bundleID: bundleID, layoutID: currentID, extra: [
                "from_lang": .string(currentLang)
            ])
            _ = handleLayoutIncidentToken(
                original: word,
                candidate: candidate,
                boundary: boundary,
                fromLayoutID: currentID,
                targetLayoutID: targetID,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: threshold,
                algorithm: algorithm,
                currentLang: currentLang,
                targetLang: targetLang,
                bundleID: bundleID,
                canMutateDirectly: canMutateDirectly,
                allowsProposal: appPolicy.allowsProposal,
                targetSession: targetSession,
                evidence: .contradiction,
                singleAction: .none
            )
            return
        }

        if Defaults[.autoFixSpellingTypoGuardEnabled] {
            let typoAssessment = AutoFixDecision.spellingTypoGuardAssessment(
                original: word,
                candidate: candidate,
                language: currentLang,
                minWordLength: Defaults[.autoFixSpellingTypoGuardMinWordLength],
                maxEditDistance: Defaults[.autoFixSpellingTypoGuardMaxEditDistance],
                isKnownCorrect: { [spellChecker] word, language in
                    !spellChecker.isMisspelled(word, language: language)
                },
                suggestions: { [spellChecker] word, language in
                    spellChecker.guesses(for: word, language: language)
                }
            )

            if typoAssessment.shouldSuppressAutoReplace {
                var extra: [String: AnalyticsValue] = [
                    "candidate": .string(candidate),
                    "from_lang": .string(currentLang),
                    "to_lang": .string(targetLang)
                ]
                if let suggestion = typoAssessment.suggestion {
                    extra["spell_suggestion"] = .string(suggestion)
                }
                if let editDistance = typoAssessment.editDistance {
                    extra["edit_distance"] = .int(editDistance)
                }
                logSkip(.likelySpellingTypo, word: word, bundleID: bundleID, extra: extra)
                observeMistakeCandidate(word: word, language: currentLang, bundleID: bundleID)
                let interruptedIncident = isCapturingLayoutIncident || pendingSingleDecision != nil
                if interruptedIncident {
                    markDecisionAggregateOnly(matching: word)
                    resetLayoutIncident()
                    return
                }
                if let suggestion = typoAssessment.suggestion,
                   let editDistance = typoAssessment.editDistance {
                    let confidence = AutoFixDecision.spellingConfidence(
                        original: word, suggestion: suggestion, editDistance: editDistance
                    )
                    if appPolicy.allowsProposal, Defaults[.autoFixProposalEnabled] {
                        showSpellingProposal(
                            original: word,
                            suggestion: suggestion,
                            confidence: confidence,
                            boundary: boundary,
                            layoutID: currentID,
                            language: currentLang,
                            algorithm: algorithm,
                            bundleID: bundleID,
                            targetSession: targetSession
                        )
                    } else {
                        updateSpellingDecision(suggestion: suggestion, source: word, confidence: confidence)
                        markDecision(
                            outcome: .skipped,
                            reason: AutoFixSkipReason.likelySpellingTypo.rawValue,
                            signalKind: .spellingSuggestion,
                            candidateOrigin: .spelling,
                            matching: word
                        )
                    }
                } else {
                    markDecisionAggregateOnly(matching: word)
                }
                resetLayoutIncident()
                return
            }
        }

        let predictionAdjustment = ProtectedLexiconPredictionScorer.adjustment(
            original: word,
            candidate: candidate,
            scoreCandidate: scoreCandidate,
            threshold: threshold
        )
        let effectiveScoreCandidate = predictionAdjustment.adjustedCandidateScore
        let effectiveThreshold = predictionAdjustment.adjustedThreshold
        updateEffectiveDecisionScore(
            effectiveCandidateScore: effectiveScoreCandidate,
            threshold: effectiveThreshold
        )

        AppLogger.post(
            logger,
            "Eval word=\(word) -> \(candidate); scores: \(scoreOriginal) vs \(effectiveScoreCandidate); threshold=\(effectiveThreshold)"
        )

        let mixedDecision = AutoFixMixedLanguagePolicy.decision(
            original: word,
            candidate: candidate,
            currentLanguage: currentLang,
            targetLanguage: targetLang,
            scoreOriginal: scoreOriginal,
            scoreCandidate: effectiveScoreCandidate,
            threshold: effectiveThreshold
        )
        if case .skipAsIntentional(let kind) = mixedDecision {
            logSkip(.mixedLanguageIntentional, word: word, bundleID: bundleID, extra: [
                "token_kind": .string(String(describing: kind)),
                "from_lang": .string(currentLang),
                "to_lang": .string(targetLang)
            ])
            resetLayoutIncident()
            return
        }

        guard AutoFixDecision.shouldReplace(
            scoreOriginal: scoreOriginal,
            scoreCandidate: effectiveScoreCandidate,
            threshold: effectiveThreshold
        ) else {
            var extra: [String: AnalyticsValue] = [
                "score_original": .double(scoreOriginal),
                "score_candidate": .double(effectiveScoreCandidate),
                "score_candidate_raw": .double(scoreCandidate),
                "algorithm": .string(algorithm.rawValue),
                "from_lang": .string(currentLang),
                "to_lang": .string(targetLang)
            ]
            if let candidateMatch = predictionAdjustment.candidateMatch {
                extra["lexicon_candidate_id"] = .string(candidateMatch.entry.id)
                extra["lexicon_reasons"] = .string(predictionAdjustment.reasons.joined(separator: ","))
            }
            logSkip(.belowThreshold, word: word, bundleID: bundleID, layoutID: currentID, extra: extra)
            observeMistakeCandidate(word: word, language: currentLang, bundleID: bundleID)
            let shouldOfferSingleProposal = appPolicy.allowsProposal && (
                AutoFixProposalPolicy.shouldSuggest(
                    scoreOriginal: scoreOriginal,
                    scoreCandidate: effectiveScoreCandidate,
                    threshold: effectiveThreshold,
                    window: Defaults[.autoFixProposalWindow]
                ) || AutoFixDecision.shouldSuggestSingleTokenLayoutMistake(
                    original: word,
                    candidate: candidate,
                    targetLanguage: targetLang,
                    scoreCandidate: effectiveScoreCandidate
                )
            )
            if handleLayoutIncidentToken(
                original: word,
                candidate: candidate,
                boundary: boundary,
                fromLayoutID: currentID,
                targetLayoutID: targetID,
                scoreOriginal: scoreOriginal,
                scoreCandidate: effectiveScoreCandidate,
                threshold: effectiveThreshold,
                algorithm: algorithm,
                currentLang: currentLang,
                targetLang: targetLang,
                bundleID: bundleID,
                canMutateDirectly: canMutateDirectly,
                allowsProposal: appPolicy.allowsProposal,
                targetSession: targetSession,
                evidence: layoutIncidentEvidence(
                    original: word,
                    candidate: candidate,
                    sourceLanguage: currentLang,
                    targetLanguage: targetLang,
                    candidateScore: effectiveScoreCandidate
                ),
                singleAction: shouldOfferSingleProposal ? .proposal(force: false) : .none
            ) {
                return
            }
            if appPolicy.allowsProposal {
                maybeShowProposal(
                    original: word,
                    candidate: candidate,
                    boundary: boundary,
                    fromLayoutID: currentID,
                    targetLayoutID: targetID,
                    scoreOriginal: scoreOriginal,
                    scoreCandidate: effectiveScoreCandidate,
                    threshold: effectiveThreshold,
                    algorithm: algorithm,
                    currentLang: currentLang,
                    targetLang: targetLang,
                    bundleID: bundleID,
                    targetSession: targetSession
                )
            }
            return
        }

        let deferredAction: DeferredSingleAction
        if !canMutateDirectly {
            deferredAction = appPolicy.allowsProposal ? .proposal(force: true) : .none
        } else if isAmbiguousTarget {
            deferredAction = appPolicy.allowsProposal ? .proposal(force: true) : .none
        } else {
            deferredAction = .replace
        }
        if handleLayoutIncidentToken(
            original: word,
            candidate: candidate,
            boundary: boundary,
            fromLayoutID: currentID,
            targetLayoutID: targetID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: effectiveScoreCandidate,
            threshold: effectiveThreshold,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            canMutateDirectly: canMutateDirectly,
            allowsProposal: appPolicy.allowsProposal,
            targetSession: targetSession,
            evidence: layoutIncidentEvidence(
                original: word,
                candidate: candidate,
                sourceLanguage: currentLang,
                targetLanguage: targetLang,
                candidateScore: effectiveScoreCandidate
            ),
            singleAction: deferredAction
        ) {
            return
        }

        guard canMutateDirectly else {
            if appPolicy.allowsProposal {
                maybeShowProposal(
                    original: word,
                    candidate: candidate,
                    boundary: boundary,
                    fromLayoutID: currentID,
                    targetLayoutID: targetID,
                    scoreOriginal: scoreOriginal,
                    scoreCandidate: effectiveScoreCandidate,
                    threshold: effectiveThreshold,
                    algorithm: algorithm,
                    currentLang: currentLang,
                    targetLang: targetLang,
                    bundleID: bundleID,
                    targetSession: targetSession,
                    force: true
                )
            } else {
                logSkip(.unsafeEditor, word: word, bundleID: bundleID, extra: [
                    "app_policy": .string(appPolicy.rawValue)
                ])
            }
            resetLayoutIncident()
            return
        }

        resetLayoutIncident()

        // Two plausible target layouts scored within the separation margin (e.g. Ukrainian vs
        // Russian on short Cyrillic text): don't guess a direction — surface a proposal instead.
        if isAmbiguousTarget {
            logSkip(.ambiguousTarget, word: word, bundleID: bundleID, layoutID: currentID, extra: [
                "from_lang": .string(currentLang),
                "to_lang": .string(targetLang),
                "runner_up_lang": .string(selection.runnerUp.map { languageHintForLayoutID($0.targetID) } ?? "")
            ])
            if appPolicy.allowsProposal {
                maybeShowProposal(
                    original: word,
                    candidate: candidate,
                    boundary: boundary,
                    fromLayoutID: currentID,
                    targetLayoutID: targetID,
                    scoreOriginal: scoreOriginal,
                    scoreCandidate: effectiveScoreCandidate,
                    threshold: effectiveThreshold,
                    algorithm: algorithm,
                    currentLang: currentLang,
                    targetLang: targetLang,
                    bundleID: bundleID,
                    targetSession: targetSession,
                    force: true
                )
            }
            return
        }

        applyFix(
            original: word,
            candidate: candidate,
            boundary: boundary,
            fromLayoutID: currentID,
            targetLayoutID: targetID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: effectiveScoreCandidate,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            targetSession: targetSession
        )
    }

    private func layoutIncidentEvidence(
        original: String,
        candidate: String,
        sourceLanguage: String,
        targetLanguage: String,
        candidateScore: Double
    ) -> LayoutIncidentToken.Evidence {
        guard AutoFixDecision.isCrossScriptConversion(original: original, candidate: candidate) else {
            return .neutral
        }

        let sourceToken = original.trimmingCharacters(in: .punctuationCharacters)
        let targetToken = candidate.trimmingCharacters(in: .punctuationCharacters)
        guard !sourceToken.isEmpty, !targetToken.isEmpty else { return .neutral }

        let sourceIsInvalid = spellChecker.isMisspelled(sourceToken, language: sourceLanguage)
        let targetIsInvalid = spellChecker.isMisspelled(targetToken, language: targetLanguage)
        if sourceIsInvalid && !targetIsInvalid {
            return .strong
        }
        if !sourceIsInvalid && targetIsInvalid {
            return .contradiction
        }
        if AutoFixDecision.shouldSuggestSingleTokenLayoutMistake(
            original: original,
            candidate: candidate,
            targetLanguage: targetLanguage,
            scoreCandidate: candidateScore
        ) {
            return .strong
        }
        return .neutral
    }

    @discardableResult
    private func handleLayoutIncidentToken(
        original: String,
        candidate: String,
        boundary: String,
        fromLayoutID: String,
        targetLayoutID: String,
        scoreOriginal: Double,
        scoreCandidate: Double,
        threshold: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        bundleID: String,
        canMutateDirectly: Bool,
        allowsProposal: Bool,
        targetSession: AutoFixTargetSession?,
        evidence: LayoutIncidentToken.Evidence,
        singleAction: DeferredSingleAction
    ) -> Bool {
        let context = LayoutIncidentContext(
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            canMutateDirectly: canMutateDirectly,
            allowsProposal: allowsProposal,
            threshold: threshold,
            targetSession: targetSession
        )
        let token = LayoutIncidentToken(
            original: original,
            candidate: candidate,
            boundary: boundary.isEmpty ? " " : boundary,
            targetLayoutID: targetLayoutID,
            evidence: evidence
        )

        if isCapturingLayoutIncident {
            if let existing = layoutIncidentContext,
               !existing.matches(context) {
                resetLayoutIncident()
            } else {
                let result = layoutIncident.append(token)
                if result == .targetChanged {
                    resetLayoutIncident()
                } else if result == .wouldExceedCap {
                    let untouchedSuffix = layoutIncident.trailingBoundary
                        + original
                        + token.boundary
                    finalizeLayoutIncident(boundaryOverride: untouchedSuffix)
                    return handleLayoutIncidentToken(
                        original: original,
                        candidate: candidate,
                        boundary: boundary,
                        fromLayoutID: fromLayoutID,
                        targetLayoutID: targetLayoutID,
                        scoreOriginal: scoreOriginal,
                        scoreCandidate: scoreCandidate,
                        threshold: threshold,
                        algorithm: algorithm,
                        currentLang: currentLang,
                        targetLang: targetLang,
                        bundleID: bundleID,
                        canMutateDirectly: canMutateDirectly,
                        allowsProposal: allowsProposal,
                        targetSession: targetSession,
                        evidence: evidence,
                        singleAction: singleAction
                    )
                } else if evidence == .contradiction {
                    markDecisionAggregateOnly(matching: original)
                    finalizeLayoutIncident()
                    return true
                } else if result == .reachedCap
                            || layoutIncident.endsSentence
                            || LayoutIncidentTracker.isHardBoundary(boundary) {
                    markDecisionAggregateOnly(matching: original)
                    finalizeLayoutIncident()
                    return true
                } else {
                    markDecisionAggregateOnly(matching: original)
                    armLayoutIncidentIdleTimer()
                    return true
                }
            }
        }

        guard evidence == .strong else { return false }
        guard layoutIncident.append(token) != .wouldExceedCap else {
            resetLayoutIncident()
            return false
        }
        layoutIncidentContext = context
        pendingSingleDecision = DeferredSingleDecision(
            action: singleAction,
            original: original,
            candidate: candidate,
            boundary: token.boundary,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: threshold,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            targetSession: targetSession
        )
        markDecisionAggregateOnly(matching: original)
        if LayoutIncidentTracker.isHardBoundary(boundary) {
            executeDeferredSingleDecision()
            return true
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        layoutIncidentTimerState.armSingleWord(at: timestamp)
        scheduleLayoutIncidentTimer(after: LayoutIncidentTimerState.singleWordGrace)
        return true
    }

    private func notePrintableContinuation(timestamp: TimeInterval) {
        if layoutIncidentTimerState.consumeFastContinuation(at: timestamp),
           pendingSingleDecision != nil {
            layoutIncidentTimerTask?.cancel()
            layoutIncidentTimerTask = nil
            pendingSingleDecision = nil
            isCapturingLayoutIncident = true
            return
        }

        if isCapturingLayoutIncident {
            layoutIncidentTimerTask?.cancel()
            layoutIncidentTimerTask = nil
            layoutIncidentTimerState.reset()
        }
    }

    private func armLayoutIncidentIdleTimer() {
        let timestamp = ProcessInfo.processInfo.systemUptime
        layoutIncidentTimerState.armIncidentIdle(at: timestamp)
        scheduleLayoutIncidentTimer(after: LayoutIncidentTimerState.incidentIdleDelay)
    }

    private func scheduleLayoutIncidentTimer(after delay: TimeInterval) {
        layoutIncidentTimerTask?.cancel()
        layoutIncidentTimerTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            self?.handleLayoutIncidentTimer(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func handleLayoutIncidentTimer(at timestamp: TimeInterval) {
        guard let action = layoutIncidentTimerState.takeDueAction(at: timestamp) else { return }
        layoutIncidentTimerTask = nil
        switch action {
        case .applySingleWord:
            executeDeferredSingleDecision()
        case .finalizeIncident:
            finalizeLayoutIncident()
        }
    }

    private func executeDeferredSingleDecision() {
        guard let decision = pendingSingleDecision else {
            resetLayoutIncident()
            return
        }
        resetLayoutIncident()

        switch decision.action {
        case .none:
            return
        case .replace:
            let didApply = applyFix(
                original: decision.original,
                candidate: decision.candidate,
                boundary: decision.boundary,
                fromLayoutID: decision.fromLayoutID,
                targetLayoutID: decision.targetLayoutID,
                scoreOriginal: decision.scoreOriginal,
                scoreCandidate: decision.scoreCandidate,
                algorithm: decision.algorithm,
                currentLang: decision.currentLang,
                targetLang: decision.targetLang,
                bundleID: decision.bundleID,
                targetSession: decision.targetSession
            )
            recordDeferredSingleDecision(
                decision,
                outcome: didApply ? .replaced : .skipped,
                reason: didApply ? nil : .targetUnverifiable,
                signalKind: didApply ? .replacement : .mutationFailure
            )
        case .proposal(let force):
            let didPresent = maybeShowProposal(
                original: decision.original,
                candidate: decision.candidate,
                boundary: decision.boundary,
                fromLayoutID: decision.fromLayoutID,
                targetLayoutID: decision.targetLayoutID,
                scoreOriginal: decision.scoreOriginal,
                scoreCandidate: decision.scoreCandidate,
                threshold: decision.threshold,
                algorithm: decision.algorithm,
                currentLang: decision.currentLang,
                targetLang: decision.targetLang,
                bundleID: decision.bundleID,
                targetSession: decision.targetSession,
                force: force
            )
            recordDeferredSingleDecision(
                decision,
                outcome: didPresent ? .proposed : .skipped,
                reason: didPresent ? nil : .targetUnverifiable,
                signalKind: didPresent ? .proposal : .mutationFailure
            )
        }
    }

    private func finalizeLayoutIncident(boundaryOverride: String? = nil) {
        guard let context = layoutIncidentContext,
              !layoutIncident.isEmpty else {
            resetLayoutIncident()
            return
        }
        let incident = layoutIncident
        resetLayoutIncident()

        let original = incident.originalBody
        let candidate = incident.candidateBody
        let untouchedBoundary = boundaryOverride ?? incident.trailingBoundary
        let scorer = resolvedScorer(for: context.algorithm)
        let scoreOriginal = scorer.score(original, expecting: context.currentLang)
        let scoreCandidate = scorer.score(candidate, expecting: context.targetLang)
        let decision = incident.decision(
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: context.threshold
        )

        guard decision != .discard,
              !AutoFixDecision.shouldSuppressPhraseAutoReplace(
                original: original,
                candidate: candidate,
                sourceLanguage: context.currentLang,
                targetLanguage: context.targetLang,
                allowlist: Defaults[.autoFixAllowlist]
              ) else {
            return
        }

        if decision == .replace, context.canMutateDirectly {
            let didApply = applyPhraseFix(
                original: original,
                candidate: candidate,
                boundary: untouchedBoundary,
                fromLayoutID: context.fromLayoutID,
                targetLayoutID: context.targetLayoutID,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                algorithm: context.algorithm,
                currentLang: context.currentLang,
                targetLang: context.targetLang,
                bundleID: context.bundleID,
                targetSession: context.targetSession
            )
            recordPhraseDecision(
                original: original,
                candidate: candidate,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: context.threshold,
                algorithm: context.algorithm,
                currentLang: context.currentLang,
                targetLang: context.targetLang,
                fromLayoutID: context.fromLayoutID,
                targetLayoutID: context.targetLayoutID,
                bundleID: context.bundleID,
                outcome: didApply ? .replaced : .skipped,
                reason: didApply ? nil : .targetUnverifiable,
                signalKind: didApply ? .layoutIncident : .mutationFailure
            )
            return
        }

        guard context.allowsProposal, Defaults[.autoFixProposalEnabled] else {
            recordPhraseDecision(
                original: original,
                candidate: candidate,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: context.threshold,
                algorithm: context.algorithm,
                currentLang: context.currentLang,
                targetLang: context.targetLang,
                fromLayoutID: context.fromLayoutID,
                targetLayoutID: context.targetLayoutID,
                bundleID: context.bundleID,
                outcome: .skipped,
                reason: context.canMutateDirectly ? .belowThreshold : .unsafeEditor,
                signalKind: .layoutIncident
            )
            return
        }

        let didPresent = maybeShowProposal(
            original: original,
            candidate: candidate,
            boundary: untouchedBoundary,
            fromLayoutID: context.fromLayoutID,
            targetLayoutID: context.targetLayoutID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: context.threshold,
            algorithm: context.algorithm,
            currentLang: context.currentLang,
            targetLang: context.targetLang,
            bundleID: context.bundleID,
            targetSession: context.targetSession,
            force: true
        )
        recordPhraseDecision(
            original: original,
            candidate: candidate,
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: context.threshold,
            algorithm: context.algorithm,
            currentLang: context.currentLang,
            targetLang: context.targetLang,
            fromLayoutID: context.fromLayoutID,
            targetLayoutID: context.targetLayoutID,
            bundleID: context.bundleID,
            outcome: didPresent ? .proposed : .skipped,
            reason: didPresent ? nil : .targetUnverifiable,
            signalKind: didPresent ? .layoutIncident : .mutationFailure
        )
    }

    private func resetLayoutIncident() {
        layoutIncidentTimerTask?.cancel()
        layoutIncidentTimerTask = nil
        layoutIncidentTimerState.reset()
        layoutIncident.reset()
        layoutIncidentContext = nil
        pendingSingleDecision = nil
        isCapturingLayoutIncident = false
    }

    @discardableResult
    private func applyPhraseFix(
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
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) -> Bool {
        guard let replacementResult = performAnchoredReplacement(
            original: original,
            candidate: candidate,
            boundary: boundary,
            bundleID: bundleID,
            targetSession: targetSession
        ) else {
            return false
        }
        AppLogger.action(logger, "Auto-fix phrase applying: \(original) -> \(candidate)")
        AutoFixProposalCoordinator.shared.dismiss()
        switchLayoutIfNeeded(
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scope: .phrase
        )

        let canUndo = setPendingUndo(
            original: original,
            replacement: candidate,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            recoveryAnchor: replacementResult.recoveryAnchor
        )

        AnalyticsCounters.recordReplacement(text: candidate)
        NotificationCenter.default.post(name: .textReplacementDidComplete, object: nil)

        if Defaults[.autoFixToastEnabled], canUndo {
            FixToastCoordinator.shared.show(near: NSEvent.mouseLocation) { [weak self] in
                self?.undoFromToast()
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
                "to_lang": .string(targetLang),
                "source": .string("phrase_auto_fix")
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
        return true
    }

    @discardableResult
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
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) -> Bool {
        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard let replacementResult = performAnchoredReplacement(
            original: original,
            candidate: candidate,
            boundary: boundaryToPreserve,
            bundleID: bundleID,
            targetSession: targetSession
        ) else {
            return false
        }
        AppLogger.action(logger, "Auto-fix applying: \(original) -> \(candidate)")
        markDecision(outcome: .replaced, reason: nil, matching: original)
        switchLayoutIfNeeded(
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scope: .singleToken
        )

        let canUndo = setPendingUndo(
            original: original,
            replacement: candidate,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            recoveryAnchor: replacementResult.recoveryAnchor
        )

        AnalyticsCounters.recordReplacement(text: candidate)
        NotificationCenter.default.post(name: .textReplacementDidComplete, object: nil)

        if Defaults[.autoFixToastEnabled], canUndo {
            let cursor = NSEvent.mouseLocation
            FixToastCoordinator.shared.show(near: cursor) { [weak self] in
                self?.undoFromToast()
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
                "to_lang": .string(targetLang),
                "source": .string("auto_fix")
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
        return true
    }

    @discardableResult
    private func maybeShowProposal(
        original: String,
        candidate: String,
        boundary: String,
        fromLayoutID: String,
        targetLayoutID: String,
        scoreOriginal: Double,
        scoreCandidate: Double,
        threshold: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?,
        force: Bool = false
    ) -> Bool {
        guard Defaults[.autoFixProposalEnabled] else { return false }
        if !force {
            let shouldSuggestNearThreshold = AutoFixProposalPolicy.shouldSuggest(
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: threshold,
                window: Defaults[.autoFixProposalWindow]
            )
            let shouldSuggestLayoutMistake = AutoFixDecision.shouldSuggestSingleTokenLayoutMistake(
                original: original,
                candidate: candidate,
                targetLanguage: targetLang,
                scoreCandidate: scoreCandidate
            )
            guard shouldSuggestNearThreshold || shouldSuggestLayoutMistake else { return false }
        }

        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard let targetSession,
              let replacementAnchor = targetValidator.captureReplacementAnchor(
                for: targetSession,
                expectedBundleID: bundleID,
                source: original,
                boundary: boundaryToPreserve
              )
        else {
            logSkip(.targetUnverifiable, word: original, bundleID: bundleID)
            return false
        }
        let proposal = AutoFixProposal(
            original: original,
            candidate: candidate,
            boundary: boundaryToPreserve,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: threshold,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            createdAt: ProcessInfo.processInfo.systemUptime,
            replacementAnchor: replacementAnchor,
            kind: .detected
        )
        markDecision(
            outcome: .proposed,
            reason: nil,
            signalKind: original.contains(where: \.isWhitespace) ? .layoutIncident : .proposal,
            candidateOrigin: .keyboardLayout,
            matching: original
        )
        presentProposal(proposal)
        return true
    }

    private func showSpellingProposal(
        original: String,
        suggestion: String,
        confidence: Double,
        boundary: String,
        layoutID: String,
        language: String,
        algorithm: LanguageScorerAlgorithm,
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) {
        guard Defaults[.autoFixProposalEnabled] else { return }
        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard let targetSession,
              let replacementAnchor = targetValidator.captureReplacementAnchor(
                for: targetSession,
                expectedBundleID: bundleID,
                source: original,
                boundary: boundaryToPreserve
              )
        else {
            logSkip(.targetUnverifiable, word: original, bundleID: bundleID)
            return
        }

        updateSpellingDecision(suggestion: suggestion, source: original, confidence: confidence)
        markDecision(
            outcome: .proposed,
            reason: AutoFixSkipReason.likelySpellingTypo.rawValue,
            signalKind: .spellingSuggestion,
            candidateOrigin: .spelling,
            matching: original
        )
        presentProposal(AutoFixProposal(
            original: original,
            candidate: suggestion,
            boundary: boundaryToPreserve,
            fromLayoutID: layoutID,
            targetLayoutID: layoutID,
            scoreOriginal: 0,
            scoreCandidate: 1,
            threshold: 0,
            algorithm: algorithm,
            currentLang: language,
            targetLang: language,
            bundleID: bundleID,
            createdAt: ProcessInfo.processInfo.systemUptime,
            replacementAnchor: replacementAnchor,
            kind: .spelling
        ))
    }

    private func showRuleProposal(
        rule: CustomAutoReplaceRule,
        original: String,
        boundary: String,
        fromLayoutID: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) {
        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard let targetSession,
              let replacementAnchor = targetValidator.captureReplacementAnchor(
                for: targetSession,
                expectedBundleID: bundleID,
                source: original,
                boundary: boundaryToPreserve
              )
        else {
            logSkip(.targetUnverifiable, word: original, bundleID: bundleID)
            return
        }
        let proposal = AutoFixProposal(
            original: original,
            candidate: rule.target,
            boundary: boundaryToPreserve,
            fromLayoutID: fromLayoutID,
            targetLayoutID: fromLayoutID,
            scoreOriginal: 0,
            scoreCandidate: 1,
            threshold: 0,
            algorithm: .appleNL,
            currentLang: languageHintForLayoutID(fromLayoutID),
            targetLang: languageHintForLayoutID(fromLayoutID),
            bundleID: bundleID,
            createdAt: ProcessInfo.processInfo.systemUptime,
            replacementAnchor: replacementAnchor,
            kind: .customRule
        )
        updateCustomRuleDecision(candidate: rule.target, source: original)
        markDecision(outcome: .proposed, reason: nil, matching: original)
        presentProposal(proposal)
    }

    private func presentProposal(_ proposal: AutoFixProposal) {
        AutoFixProposalCoordinator.shared.show(
            proposal: proposal,
            near: NSEvent.mouseLocation,
            actions: AutoFixProposalActions(
                replace: { [weak self] in
                    self?.acceptProposal(proposal)
                },
                dismiss: { [weak self] in
                    self?.showProposalRecovery(proposal)
                },
                timedOut: { [weak self] in
                    self?.showProposalRecovery(proposal)
                },
                neverReplace: { [weak self] in
                    self?.neverReplace(proposal)
                }
            )
        )
    }

    private func acceptProposal(_ proposal: AutoFixProposal) {
        switch proposal.kind {
        case .detected:
            let canCreateRule = canCreateRule(from: proposal)
            let historyKind: ReplacementHistoryEntry.Kind = canCreateRule ? .autoRuleApplied : .autoFixApplied
            if applyProposal(
                proposal,
                source: canCreateRule ? "proposal_auto_rule" : "proposal",
                historyKind: historyKind
            ), canCreateRule {
                createRuleFromProposal(proposal)
            }
        case .customRule:
            _ = applyProposal(proposal, source: "custom_rule_proposal", historyKind: .autoRuleApplied)
        case .spelling:
            _ = applyProposal(proposal, source: "spelling_proposal", historyKind: .autoFixApplied)
        }
    }

    @discardableResult
    private func applyProposal(
        _ proposal: AutoFixProposal,
        source: String,
        historyKind: ReplacementHistoryEntry.Kind = .autoFixApplied
    ) -> Bool {
        guard let replacementResult = targetValidator.replaceAnchoredText(
            proposal.replacementAnchor,
            with: proposal.candidate
        ) else {
            recordMutationFailure(
                source: proposal.original,
                candidate: proposal.candidate,
                fromLayoutID: proposal.fromLayoutID,
                targetLayoutID: proposal.targetLayoutID,
                bundleID: proposal.bundleID,
                scope: proposal.original.contains(where: \.isWhitespace) ? .phrase : .word,
                algorithm: proposal.algorithm,
                sourceLanguage: proposal.currentLang,
                targetLanguage: proposal.targetLang,
                candidateOrigin: proposal.candidateOrigin
            )
            return false
        }
        AppLogger.action(logger, "AutoFix proposal accepted: \(proposal.original) -> \(proposal.candidate)")
        resetLayoutIncident()
        let replacementScope: ReplacementScope = proposal.original.contains(where: \.isWhitespace) ? .phrase : .singleToken
        if proposal.changesInputLayout {
            switchLayoutIfNeeded(
                fromLayoutID: proposal.fromLayoutID,
                targetLayoutID: proposal.targetLayoutID,
                scope: replacementScope
            )
        }

        let canUndo = setPendingUndo(
            original: proposal.original,
            replacement: proposal.candidate,
            fromLayoutID: proposal.fromLayoutID,
            targetLayoutID: proposal.targetLayoutID,
            changesInputLayout: proposal.changesInputLayout,
            recoveryAnchor: replacementResult.recoveryAnchor
        )

        AnalyticsCounters.recordReplacement(text: proposal.candidate)
        NotificationCenter.default.post(name: .textReplacementDidComplete, object: nil)

        if Defaults[.autoFixToastEnabled], canUndo {
            FixToastCoordinator.shared.show(near: NSEvent.mouseLocation) { [weak self] in
                self?.undoFromToast()
            }
        }

        PapugaEventLog.shared.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixApplied,
            frontmostBundleID: proposal.bundleID,
            inputLayout: proposal.targetLayoutID,
            properties: [
                "original_length": .int(proposal.original.count),
                "replacement_length": .int(proposal.candidate.count),
                "score_original": .double(proposal.scoreOriginal),
                "score_candidate": .double(proposal.scoreCandidate),
                "algorithm": .string(proposal.algorithm.rawValue),
                "from_lang": .string(proposal.currentLang),
                "to_lang": .string(proposal.targetLang),
                "source": .string(source)
            ]
        ))

        ReplacementHistoryStore.shared.record(
            ReplacementHistoryEntry(
                kind: historyKind,
                original: proposal.original,
                converted: proposal.candidate,
                sourceLayoutID: proposal.fromLayoutID,
                targetLayoutID: proposal.targetLayoutID,
                bundleID: proposal.bundleID
            )
        )
        return true
    }

    private func createRuleFromProposal(_ proposal: AutoFixProposal) {
        guard canCreateRule(from: proposal) else { return }
        var rules = Defaults[.customAutoReplaceRules]
        rules.removeAll { $0.source.caseInsensitiveCompare(proposal.original) == .orderedSame }
        rules.append(CustomAutoReplaceRule(
            source: proposal.original,
            target: proposal.candidate,
            createdFromRecommendation: true
        ))
        Defaults[.customAutoReplaceRules] = rules
        cachedCustomRules = rules

        var allowlist = Defaults[.autoFixAllowlist]
        allowlist.removeAll { $0.caseInsensitiveCompare(proposal.original) == .orderedSame }
        Defaults[.autoFixAllowlist] = allowlist
    }

    private func canCreateRule(from proposal: AutoFixProposal) -> Bool {
        guard proposal.createsRuleOnAcceptance else { return false }
        let source = proposal.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = proposal.candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return !source.isEmpty
            && !target.isEmpty
            && !source.contains(where: \.isWhitespace)
            && !target.contains(where: \.isWhitespace)
    }

    private func neverReplace(_ proposal: AutoFixProposal) {
        IgnoreWordService.add(proposal.original)
        cachedCustomRules = Defaults[.customAutoReplaceRules]
        clearRecovery()
    }

    private func showProposalRecovery(_ proposal: AutoFixProposal) {
        let pending = PendingProposalRecovery(
            proposal: proposal,
            expiresAt: ProcessInfo.processInfo.systemUptime + 10
        )
        pendingProposalRecovery = pending
        pendingReapply = nil
        FixToastCoordinator.shared.showRecovery(
            title: "Повернути підказку",
            near: NSEvent.mouseLocation
        ) { [weak self] in
            self?.reopenProposalRecovery()
        }
    }

    private func reopenProposalRecovery() {
        guard let pending = pendingProposalRecovery,
              pending.isValid(at: ProcessInfo.processInfo.systemUptime),
              targetValidator.isReplacementAnchorValid(pending.proposal.replacementAnchor)
        else {
            clearRecovery()
            return
        }
        pendingProposalRecovery = nil
        presentProposal(pending.proposal)
    }

    private func showReapplyRecovery(_ pending: PendingReapply) {
        pendingReapply = pending
        pendingProposalRecovery = nil
        FixToastCoordinator.shared.showRecovery(
            title: "Застосувати знову",
            near: NSEvent.mouseLocation
        ) { [weak self] in
            self?.reapplyPendingFix()
        }
    }

    private func reapplyPendingFix() {
        guard let pending = pendingReapply,
              pending.isValid(at: ProcessInfo.processInfo.systemUptime) else {
            clearRecovery()
            return
        }
        guard let replacementResult = targetValidator.replaceAnchoredText(
            pending.replacementAnchor,
            with: pending.replacement
        ) else {
            recordMutationFailure(
                source: pending.original,
                candidate: pending.replacement,
                fromLayoutID: pending.fromLayoutID,
                targetLayoutID: pending.targetLayoutID,
                bundleID: AppContextProvider.frontmostBundleID() ?? "",
                scope: pending.original.contains(where: \.isWhitespace) ? .phrase : .word
            )
            clearRecovery()
            return
        }
        pendingReapply = nil
        if pending.changesInputLayout {
            layoutManager.switchTo(pending.targetLayoutID)
        }
        let canUndo = setPendingUndo(
            original: pending.original,
            replacement: pending.replacement,
            fromLayoutID: pending.fromLayoutID,
            targetLayoutID: pending.targetLayoutID,
            changesInputLayout: pending.changesInputLayout,
            recoveryAnchor: replacementResult.recoveryAnchor
        )
        AnalyticsCounters.recordReplacement(text: pending.replacement)
        NotificationCenter.default.post(name: .textReplacementDidComplete, object: nil)
        if Defaults[.autoFixToastEnabled], canUndo {
            FixToastCoordinator.shared.show(near: NSEvent.mouseLocation) { [weak self] in
                self?.undoFromToast()
            }
        }
    }

    private func clearRecovery() {
        pendingProposalRecovery = nil
        pendingReapply = nil
        FixToastCoordinator.shared.dismiss()
    }

    @discardableResult
    private func setPendingUndo(
        original: String,
        replacement: String,
        fromLayoutID: String,
        targetLayoutID: String,
        changesInputLayout: Bool = true,
        recoveryAnchor: TextReplacementAnchor?
    ) -> Bool {
        guard let recoveryAnchor else {
            lastFix = nil
            return false
        }
        lastFix = PendingUndo(
            original: original,
            replacement: replacement,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            changesInputLayout: changesInputLayout,
            timestamp: ProcessInfo.processInfo.systemUptime,
            replacementAnchor: recoveryAnchor
        )
        return true
    }

    private func applyCustomRule(
        rule: CustomAutoReplaceRule,
        original: String,
        boundary: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) {
        let boundaryToPreserve = boundary.isEmpty ? " " : boundary
        guard let replacementResult = performAnchoredReplacement(
            original: original,
            candidate: rule.target,
            boundary: boundaryToPreserve,
            bundleID: bundleID,
            targetSession: targetSession
        ) else {
            return
        }
        AppLogger.action(logger, "Custom rule applying: \(rule.source) -> \(rule.target)")
        updateCustomRuleDecision(candidate: rule.target, source: original)
        markDecision(outcome: .ruleApplied, reason: nil, matching: original)
        let fromLayoutID = layoutManager.getCurrentLayoutID()

        let canUndo = setPendingUndo(
            original: original,
            replacement: rule.target,
            fromLayoutID: fromLayoutID,
            targetLayoutID: fromLayoutID,
            changesInputLayout: false,
            recoveryAnchor: replacementResult.recoveryAnchor
        )

        AnalyticsCounters.recordReplacement(text: rule.target)
        NotificationCenter.default.post(name: .textReplacementDidComplete, object: nil)

        if Defaults[.autoFixToastEnabled], canUndo {
            let cursor = NSEvent.mouseLocation
            FixToastCoordinator.shared.show(near: cursor) { [weak self] in
                self?.undoFromToast()
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
                kind: .autoRuleApplied,
                original: original,
                converted: rule.target,
                sourceLayoutID: fromLayoutID,
                targetLayoutID: nil,
                bundleID: bundleID
            )
        )
    }

    private func beginDecision(
        source: String,
        sourceLayoutID: String,
        sourceLanguage: String,
        bundleID: String,
        algorithm: LanguageScorerAlgorithm
    ) {
        activeDecisionDraft = AutoFixDecisionDraft(
            id: UUID(),
            timestamp: Date(),
            source: source,
            selectedCandidate: nil,
            candidates: [],
            originalScore: nil,
            rawCandidateScore: nil,
            effectiveCandidateScore: nil,
            confidence: nil,
            threshold: Defaults[.autoFixThreshold],
            proposalWindow: Defaults[.autoFixProposalWindow],
            candidateSeparation: Defaults[.autoFixCandidateSeparation],
            minimumWordLength: Defaults[.autoFixMinWordLength],
            algorithm: algorithm,
            outcome: .skipped,
            reason: nil,
            scope: .word,
            sourceLayoutID: sourceLayoutID,
            targetLayoutID: nil,
            sourceLanguage: sourceLanguage,
            targetLanguage: nil,
            bundleID: bundleID.isEmpty ? nil : bundleID,
            signalKind: nil,
            candidateOrigin: nil,
            aggregateOnly: false
        )
    }

    private func finishDecision() {
        guard let draft = activeDecisionDraft else { return }
        activeDecisionDraft = nil
        decisionHistory.record(draft.observation)
    }

    private func updateDecisionCandidates(
        scoreOriginal: Double,
        candidates: [AutoFixTargetCandidate],
        threshold: Double
    ) {
        guard var draft = activeDecisionDraft else { return }
        draft.originalScore = scoreOriginal
        draft.threshold = threshold
        draft.candidates = candidates.map {
            AutoFixScoredCandidate(
                text: $0.candidate,
                targetLayoutID: $0.targetID,
                language: $0.targetLang,
                score: $0.scoreCandidate
            )
        }
        activeDecisionDraft = draft
    }

    private func selectDecisionCandidate(_ candidate: AutoFixTargetCandidate) {
        guard var draft = activeDecisionDraft else { return }
        draft.selectedCandidate = candidate.candidate
        draft.rawCandidateScore = candidate.scoreCandidate
        draft.effectiveCandidateScore = candidate.scoreCandidate
        draft.confidence = nil
        draft.targetLayoutID = candidate.targetID
        draft.targetLanguage = candidate.targetLang
        draft.candidateOrigin = .keyboardLayout
        activeDecisionDraft = draft
    }

    private func updateEffectiveDecisionScore(effectiveCandidateScore: Double, threshold: Double) {
        guard var draft = activeDecisionDraft else { return }
        draft.effectiveCandidateScore = effectiveCandidateScore
        draft.threshold = threshold
        activeDecisionDraft = draft
    }

    private func updateCustomRuleDecision(candidate: String, source: String) {
        guard var draft = activeDecisionDraft, draft.source == source else { return }
        draft.scope = .customRule
        draft.selectedCandidate = candidate
        draft.confidence = 1
        draft.candidateOrigin = .customRule
        activeDecisionDraft = draft
    }

    private func updateSpellingDecision(suggestion: String, source: String, confidence: Double) {
        guard var draft = activeDecisionDraft, draft.source == source else { return }
        draft.selectedCandidate = suggestion
        draft.candidates = []
        draft.rawCandidateScore = nil
        draft.effectiveCandidateScore = nil
        draft.confidence = confidence
        draft.targetLayoutID = draft.sourceLayoutID
        draft.targetLanguage = draft.sourceLanguage
        draft.candidateOrigin = .spelling
        activeDecisionDraft = draft
    }

    private func markDecisionAggregateOnly(matching source: String) {
        guard var draft = activeDecisionDraft, draft.source == source else { return }
        draft.aggregateOnly = true
        activeDecisionDraft = draft
    }

    private func recordPhraseDecision(
        original: String,
        candidate: String?,
        scoreOriginal: Double?,
        scoreCandidate: Double?,
        threshold: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        fromLayoutID: String,
        targetLayoutID: String,
        bundleID: String,
        outcome: AutoFixDecisionObservation.Outcome,
        reason: AutoFixSkipReason?,
        signalKind: AutoFixDecisionSignalKind? = nil
    ) {
        let scoredCandidates = candidate.flatMap { candidate in
            scoreCandidate.map {
                [AutoFixScoredCandidate(
                    text: candidate,
                    targetLayoutID: targetLayoutID,
                    language: targetLang,
                    score: $0
                )]
            }
        } ?? []
        decisionHistory.record(AutoFixDecisionObservation(
            source: original,
            selectedCandidate: candidate,
            candidates: scoredCandidates,
            originalScore: scoreOriginal,
            rawCandidateScore: scoreCandidate,
            effectiveCandidateScore: scoreCandidate,
            threshold: threshold,
            proposalWindow: Defaults[.autoFixProposalWindow],
            candidateSeparation: Defaults[.autoFixCandidateSeparation],
            minimumWordLength: Defaults[.autoFixMinWordLength],
            algorithm: algorithm,
            outcome: outcome,
            reason: reason?.rawValue,
            scope: .phrase,
            sourceLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            sourceLanguage: currentLang,
            targetLanguage: targetLang,
            bundleID: bundleID.isEmpty ? nil : bundleID,
            signalKind: signalKind ?? (outcome == .replaced || outcome == .proposed ? .layoutIncident : nil),
            candidateOrigin: .keyboardLayout
        ))
    }

    private func recordDeferredSingleDecision(
        _ decision: DeferredSingleDecision,
        outcome: AutoFixDecisionObservation.Outcome,
        reason: AutoFixSkipReason?,
        signalKind: AutoFixDecisionSignalKind
    ) {
        decisionHistory.record(AutoFixDecisionObservation(
            source: decision.original,
            selectedCandidate: decision.candidate,
            candidates: [AutoFixScoredCandidate(
                text: decision.candidate,
                targetLayoutID: decision.targetLayoutID,
                language: decision.targetLang,
                score: decision.scoreCandidate
            )],
            originalScore: decision.scoreOriginal,
            rawCandidateScore: decision.scoreCandidate,
            effectiveCandidateScore: decision.scoreCandidate,
            threshold: decision.threshold,
            proposalWindow: Defaults[.autoFixProposalWindow],
            candidateSeparation: Defaults[.autoFixCandidateSeparation],
            minimumWordLength: Defaults[.autoFixMinWordLength],
            algorithm: decision.algorithm,
            outcome: outcome,
            reason: reason?.rawValue,
            scope: .word,
            sourceLayoutID: decision.fromLayoutID,
            targetLayoutID: decision.targetLayoutID,
            sourceLanguage: decision.currentLang,
            targetLanguage: decision.targetLang,
            bundleID: decision.bundleID.isEmpty ? nil : decision.bundleID,
            signalKind: signalKind,
            candidateOrigin: .keyboardLayout
        ))
    }

    private func recordMutationFailure(
        source: String,
        candidate: String,
        fromLayoutID: String,
        targetLayoutID: String,
        bundleID: String,
        scope: AutoFixDecisionObservation.Scope,
        algorithm: LanguageScorerAlgorithm = .appleNL,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        candidateOrigin: AutoFixDecisionCandidateOrigin = .keyboardLayout
    ) {
        decisionHistory.record(AutoFixDecisionObservation(
            source: source,
            selectedCandidate: candidate,
            threshold: Defaults[.autoFixThreshold],
            proposalWindow: Defaults[.autoFixProposalWindow],
            candidateSeparation: Defaults[.autoFixCandidateSeparation],
            minimumWordLength: Defaults[.autoFixMinWordLength],
            algorithm: algorithm,
            outcome: .skipped,
            reason: AutoFixSkipReason.replacementNotCommitted.rawValue,
            scope: scope,
            sourceLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            sourceLanguage: sourceLanguage ?? languageHintForLayoutID(fromLayoutID),
            targetLanguage: targetLanguage ?? languageHintForLayoutID(targetLayoutID),
            bundleID: bundleID.isEmpty ? nil : bundleID,
            signalKind: .mutationFailure,
            candidateOrigin: candidateOrigin
        ))
    }

    private func markDecision(
        outcome: AutoFixDecisionObservation.Outcome,
        reason: String?,
        signalKind: AutoFixDecisionSignalKind? = nil,
        candidateOrigin: AutoFixDecisionCandidateOrigin? = nil,
        matching source: String
    ) {
        guard var draft = activeDecisionDraft, draft.source == source else { return }
        draft.outcome = outcome
        draft.reason = reason
        if let signalKind { draft.signalKind = signalKind }
        if let candidateOrigin { draft.candidateOrigin = candidateOrigin }
        activeDecisionDraft = draft
    }

    private func logSkip(
        _ reason: AutoFixSkipReason,
        word: String,
        bundleID: String,
        layoutID: String? = nil,
        extra: [String: AnalyticsValue] = [:]
    ) {
        AppLogger.post(logger, "auto-fix skipped: reason=\(reason.rawValue) word=\(word)")
        markDecision(outcome: .skipped, reason: reason.rawValue, matching: word)
        var props: [String: AnalyticsValue] = [
            "reason": .string(reason.rawValue),
            "word_length": .int(word.count)
        ]
        for (k, v) in extra { props[k] = v }
        // Reuse the layout id the caller already resolved on the hot path; only query TIS again
        // when a caller (rare skip reasons) didn't pass one.
        PapugaEventLog.shared.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixSkipped,
            frontmostBundleID: bundleID,
            inputLayout: layoutID ?? layoutManager.getCurrentLayoutID(),
            properties: props
        ))
    }

    private func observeMistakeCandidate(word: String, language: String, bundleID: String) {
        mistakeEngine.observeCompletedWord(
            CompletedWordObservation(
                word: word,
                language: language,
                bundleID: bundleID.isEmpty ? nil : bundleID,
                timestamp: Date(),
                allowlist: Defaults[.autoFixAllowlist],
                blocklist: Defaults[.autoFixBlocklist],
                minWordLength: Defaults[.autoFixMinWordLength]
            )
        )
    }

    private func performAnchoredReplacement(
        original: String,
        candidate: String,
        boundary: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) -> TextReplacementResult? {
        guard let targetSession else {
            logSkip(.targetUnverifiable, word: original, bundleID: bundleID, extra: [
                "target_reason": .string("missing_session")
            ])
            return nil
        }
        guard let anchor = targetValidator.captureReplacementAnchor(
            for: targetSession,
            expectedBundleID: bundleID,
            source: original,
            boundary: boundary
        ) else {
            logSkip(.targetUnverifiable, word: original, bundleID: bundleID, extra: [
                "target_reason": .string("range_validation_failed")
            ])
            return nil
        }
        guard let replacementResult = targetValidator.replaceAnchoredText(anchor, with: candidate) else {
            logSkip(.replacementNotCommitted, word: original, bundleID: bundleID, extra: [
                "target_reason": .string("editor_content_mismatch")
            ])
            return nil
        }
        return replacementResult
    }

    private func switchLayoutIfNeeded(
        fromLayoutID: String,
        targetLayoutID: String,
        scope: ReplacementScope
    ) {
        let policy = AutoFixLayoutSwitchPolicy(rawValue: Defaults[.autoFixLayoutSwitchPolicy]) ?? .adaptive

        switch policy {
        case .alwaysSwitchToReplacementLayout:
            layoutManager.switchTo(targetLayoutID)
            return
        case .keepCurrentLayout:
            return
        case .adaptive:
            break
        }

        switch scope {
        case .phrase:
            layoutManager.switchTo(targetLayoutID)
        case .customRule:
            return
        case .singleToken:
            if var current = consecutiveReplacementDirection,
               current.fromLayoutID == fromLayoutID,
               current.targetLayoutID == targetLayoutID {
                current.count += 1
                consecutiveReplacementDirection = current
            } else {
                consecutiveReplacementDirection = AutoFixReplacementDirection(
                    fromLayoutID: fromLayoutID,
                    targetLayoutID: targetLayoutID,
                    count: 1
                )
            }

            if (consecutiveReplacementDirection?.count ?? 0) >= 2 {
                layoutManager.switchTo(targetLayoutID)
            }
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

private enum DeferredSingleAction {
    case none
    case replace
    case proposal(force: Bool)
}

private struct DeferredSingleDecision {
    let action: DeferredSingleAction
    let original: String
    let candidate: String
    let boundary: String
    let fromLayoutID: String
    let targetLayoutID: String
    let scoreOriginal: Double
    let scoreCandidate: Double
    let threshold: Double
    let algorithm: LanguageScorerAlgorithm
    let currentLang: String
    let targetLang: String
    let bundleID: String
    let targetSession: AutoFixTargetSession?
}

private struct LayoutIncidentContext {
    let fromLayoutID: String
    let targetLayoutID: String
    let algorithm: LanguageScorerAlgorithm
    let currentLang: String
    let targetLang: String
    let bundleID: String
    let canMutateDirectly: Bool
    let allowsProposal: Bool
    let threshold: Double
    let targetSession: AutoFixTargetSession?

    func matches(_ other: LayoutIncidentContext) -> Bool {
        fromLayoutID == other.fromLayoutID
            && targetLayoutID == other.targetLayoutID
            && algorithm == other.algorithm
            && currentLang == other.currentLang
            && targetLang == other.targetLang
            && bundleID == other.bundleID
    }
}


private struct PendingUndo {
    let original: String
    let replacement: String
    let fromLayoutID: String
    let targetLayoutID: String
    let changesInputLayout: Bool
    let timestamp: TimeInterval
    let replacementAnchor: TextReplacementAnchor
}

private struct PendingReapply {
    let original: String
    let replacement: String
    let fromLayoutID: String
    let targetLayoutID: String
    let changesInputLayout: Bool
    let replacementAnchor: TextReplacementAnchor
    let expiresAt: TimeInterval

    func isValid(at timestamp: TimeInterval) -> Bool {
        timestamp < expiresAt
    }
}

private struct AutoFixDecisionDraft {
    let id: UUID
    let timestamp: Date
    let source: String
    var selectedCandidate: String?
    var candidates: [AutoFixScoredCandidate]
    var originalScore: Double?
    var rawCandidateScore: Double?
    var effectiveCandidateScore: Double?
    var confidence: Double?
    var threshold: Double
    let proposalWindow: Double
    let candidateSeparation: Double
    let minimumWordLength: Int
    let algorithm: LanguageScorerAlgorithm
    var outcome: AutoFixDecisionObservation.Outcome
    var reason: String?
    var scope: AutoFixDecisionObservation.Scope
    let sourceLayoutID: String?
    var targetLayoutID: String?
    let sourceLanguage: String?
    var targetLanguage: String?
    let bundleID: String?
    var signalKind: AutoFixDecisionSignalKind?
    var candidateOrigin: AutoFixDecisionCandidateOrigin?
    var aggregateOnly: Bool

    var observation: AutoFixDecisionObservation {
        AutoFixDecisionObservation(
            id: id,
            timestamp: timestamp,
            source: source,
            selectedCandidate: selectedCandidate,
            candidates: candidates,
            originalScore: originalScore,
            rawCandidateScore: rawCandidateScore,
            effectiveCandidateScore: effectiveCandidateScore,
            confidence: confidence,
            threshold: threshold,
            proposalWindow: proposalWindow,
            candidateSeparation: candidateSeparation,
            minimumWordLength: minimumWordLength,
            algorithm: algorithm,
            outcome: outcome,
            reason: reason,
            scope: scope,
            sourceLayoutID: sourceLayoutID,
            targetLayoutID: targetLayoutID,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            bundleID: bundleID,
            signalKind: signalKind,
            candidateOrigin: candidateOrigin,
            aggregateOnly: aggregateOnly
        )
    }
}

private enum ReplacementScope {
    case singleToken
    case phrase
    case customRule
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
    if controller.handleProposalShortcutSynchronously(type: type, event: event) {
        return nil
    }
    controller.handleEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

/// Owns a `CGEventTap` and runs it on a dedicated high-priority thread so the callback is serviced
/// independently of the main run loop. All cross-thread state (the Mach port + run loop) is guarded
/// by a lock; the C callback itself never touches this state (it routes through the controller).
final class AutoFixEventTap: @unchecked Sendable {
    private struct State {
        var eventTap: CFMachPort?
        var runLoop: CFRunLoop?
        var running = false
    }

    private let mask: CGEventMask
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var thread: Thread?
    private var userInfo: UnsafeMutableRawPointer?
    private var callback: CGEventTapCallBack?

    init(mask: CGEventMask) {
        self.mask = mask
    }

    var isActive: Bool {
        state.withLock { $0.running }
    }

    /// Spins up the tap thread. Returns false if a tap could not be created.
    @discardableResult
    func start(userInfo: UnsafeMutableRawPointer, callback: @escaping CGEventTapCallBack) -> Bool {
        guard thread == nil else { return state.withLock { $0.running } }
        self.userInfo = userInfo
        self.callback = callback

        let thread = Thread { [weak self] in
            self?.threadMain()
        }
        thread.name = "ua.com.rmarinsky.papuga.autofix-tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        return true
    }

    private func threadMain() {
        guard let userInfo, let callback,
              let tap = CGEvent.tapCreate(
                  tap: .cgSessionEventTap,
                  place: .headInsertEventTap,
                  options: .defaultTap,
                  eventsOfInterest: mask,
                  callback: callback,
                  userInfo: userInfo
              )
        else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state.withLock {
            $0.eventTap = tap
            $0.runLoop = runLoop
            $0.running = true
        }

        CFRunLoopRun()

        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        state.withLock {
            $0.eventTap = nil
            $0.runLoop = nil
            $0.running = false
        }
    }

    /// Re-enable the tap after the system disabled it (timeout / user input). Safe from any thread.
    func reEnable() {
        state.withLock { state in
            if let tap = state.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    func stop() {
        let runLoop: CFRunLoop? = state.withLock { state in
            if let tap = state.eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            return state.runLoop
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        thread = nil
        userInfo = nil
        callback = nil
    }
}
