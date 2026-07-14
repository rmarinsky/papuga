import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Defaults
import Foundation
import os

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
    private var sessionRejected = Set<String>()
    private var editingGuard = AutoFixEditingGuard()
    private var phraseBuffer = PhraseBuffer(maxWords: 6)
    private let mistakeEngine: MistakeObservationEngine
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
    private lazy var syntheticEventSource = CGEventSource(stateID: .hidSystemState)
    /// Cached copy of the Defaults-backed rule list. Avoids a JSON decode on every word boundary;
    /// kept in sync via a Defaults observer so AISuggestionApplier writes are also captured.
    private var cachedCustomRules: [CustomAutoReplaceRule] = Defaults[.customAutoReplaceRules]
    private var customRulesObservation: Defaults.Observation?

    init(
        layoutManager: LayoutManager,
        characterMapper: CharacterMapper,
        mistakeEngine: MistakeObservationEngine = .shared
    ) {
        self.layoutManager = layoutManager
        self.characterMapper = characterMapper
        self.mistakeEngine = mistakeEngine
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
        undo(pending, boundaryAlreadyConsumed: false)
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
        buffer.reset()
        if clearLastFix {
            lastFix = nil
        }
        editingGuard.reset()
        phraseBuffer.reset()
        manualCorrectionTracker.resetEditingState()
        targetValidator.reset()
        consecutiveReplacementDirection = nil
    }

    fileprivate nonisolated func handleEvent(type: CGEventType, event: CGEvent) {
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

        AutoFixProposalCoordinator.shared.dismiss()

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

        if isWordBoundary(keyCode: keyCode, typedString: typedString) {
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
        manualCorrectionTracker.noteBackspace(bufferWasEmpty: bufferWasEmpty, timestamp: timestamp)
        editingGuard.noteBackspace(bufferWasEmpty: bufferWasEmpty, enabled: Defaults[.autoFixConservativeEditingGuard])
        phraseBuffer.reset()
        buffer.popLast()
        if buffer.text.isEmpty {
            targetValidator.reset()
        }
    }

    private func undoAndAddToAllowlist() {
        guard let pending = lastFix else { return }
        IgnoreWordService.add(pending.original)
        // Toast click: replacement + boundary are still in the buffer.
        undo(pending, boundaryAlreadyConsumed: false)
        lastFix = nil
    }

    private func undo(_ pending: PendingUndo, boundaryAlreadyConsumed: Bool) {
        let bundleID = AppContextProvider.frontmostBundleID() ?? ""
        guard mutationIsStillSafe(targetSession: pending.targetSession, bundleID: bundleID, word: pending.replacement) else {
            return
        }
        AppLogger.action(logger, "Undoing recent auto-fix: \(pending.replacement) -> \(pending.original)")
        let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - pending.timestamp) * 1000)
        sessionRejected.insert(BufferedToken(rawText: pending.original, keyCodes: []).core)
        layoutManager.switchTo(pending.fromLayoutID)
        if boundaryAlreadyConsumed {
            deleteCharacters(count: pending.replacement.count)
            typeText(pending.original)
        } else {
            deleteCharacters(count: pending.replacement.count + pending.boundary.count)
            typeText(pending.original + pending.boundary)
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
        let token = buffer.token
        let word = token.rawText
        let coreWord = token.core
        guard !word.isEmpty else {
            // Boundary fired with nothing typed: the latch is cleared by noteBoundary in the caller.
            return
        }

        let bundleID = AppContextProvider.frontmostBundleID() ?? ""
        let currentID = layoutManager.getCurrentLayoutID()
        let currentLang = languageHintForLayoutID(currentID)
        let targetSession = targetValidator.session
        let targetValidation = targetValidator.validateCurrentTarget(expectedBundleID: bundleID)
        if case .changed(let reason) = targetValidation {
            logSkip(.targetChanged, word: word, bundleID: bundleID, extra: [
                "target_reason": .string(reason),
                "from_lang": .string(currentLang)
            ])
            phraseBuffer.reset()
            return
        }

        let appPolicy = AutoFixAppPolicyResolver.policy(for: bundleID)
        guard appPolicy != .disabled else {
            logSkip(.unsafeEditor, word: word, bundleID: bundleID, extra: [
                "app_policy": .string(appPolicy.rawValue)
            ])
            phraseBuffer.reset()
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
            phraseBuffer.reset()
            return
        }

        if Defaults[.autoFixBlocklist].contains(bundleID) {
            logSkip(.blocklist, word: word, bundleID: bundleID)
            phraseBuffer.reset()
            return
        }

        if let rule = cachedCustomRules.first(where: { $0.matches(token) }) {
            phraseBuffer.reset()
            let plan = token.replacementPlan(
                correctedCore: BufferedToken(rawText: rule.target, keyCodes: []).core,
                boundary: boundary,
                reason: .customRule
            )
            if canMutateDirectly {
                applyCustomRule(
                    rule: rule,
                    plan: plan,
                    bundleID: bundleID,
                    targetSession: targetSession
                )
            } else if appPolicy.allowsProposal {
                showRuleProposal(
                    rule: rule,
                    plan: plan,
                    fromLayoutID: currentID,
                    bundleID: bundleID,
                    targetSession: targetSession,
                    canApplyDirectly: false
                )
            } else {
                logSkip(.unsafeEditor, word: word, bundleID: bundleID)
            }
            return
        }

        if AutoFixDecision.isInAllowlist(coreWord, allowlist: Defaults[.autoFixAllowlist]) {
            logSkip(.allowlist, word: word, bundleID: bundleID)
            phraseBuffer.reset()
            return
        }

        if let protectedMatch = ProtectedLexiconStore.shared.match(coreWord),
           protectedMatch.protectsSource {
            logSkip(.mixedLanguageIntentional, word: word, bundleID: bundleID, extra: [
                "token_kind": .string(String(describing: AutoFixTokenClassifier.classify(coreWord))),
                "lexicon_entry_id": .string(protectedMatch.entry.id),
                "lexicon_source": .string(protectedMatch.entry.source),
                "from_lang": .string(currentLang)
            ])
            phraseBuffer.reset()
            return
        }

        let skipReason = AutoFixDecision.shouldSkipWord(coreWord, minLength: Defaults[.autoFixMinWordLength])
        if let skip = skipReason {
            switch skip {
            case .tooShort:
                break
            case .containsDigits, .containsForbiddenChars:
                logSkip(.containsDigits, word: word, bundleID: bundleID)
                phraseBuffer.reset()
                return
            }
        }
        if sessionRejected.contains(coreWord) {
            logSkip(.recentlyRejected, word: word, bundleID: bundleID)
            phraseBuffer.reset()
            return
        }

        let candidateTargetIDs = layoutManager.candidateTargets(excluding: currentID)
        guard !candidateTargetIDs.isEmpty else {
            logSkip(.noTargetLayout, word: word, bundleID: bundleID)
            observeMistakeCandidate(word: word, language: currentLang, bundleID: bundleID)
            phraseBuffer.reset()
            return
        }
        guard let currentSrc = layoutManager.sourceForID(currentID) else {
            logSkip(.missingMaps, word: word, bundleID: bundleID)
            observeMistakeCandidate(word: word, language: currentLang, bundleID: bundleID)
            phraseBuffer.reset()
            return
        }
        characterMapper.buildMap(for: currentSrc, sourceID: currentID)

        let algorithm = (LanguageScorerAlgorithm(rawValue: Defaults[.autoFixAlgorithm]) ?? .appleNL).resolvedImplementation
        let scorer = resolvedScorer(for: algorithm)
        let threshold = Defaults[.autoFixThreshold]
        let scoreOriginal = scorer.score(coreWord, expecting: currentLang)

        // Evaluate EVERY configured layout, not just the next one in the cycle, and let the language
        // scorer decide which target is correct. This fixes wrong-direction conversions when 3+
        // layouts are configured (e.g. US + Ukrainian + Russian), where "next in cycle" is often
        // the wrong language.
        var evaluatedCandidates: [AutoFixTargetCandidate] = []
        for candidateTargetID in candidateTargetIDs {
            guard let candidateSrc = layoutManager.sourceForID(candidateTargetID) else { continue }
            characterMapper.buildMap(for: candidateSrc, sourceID: candidateTargetID)
            let mappedLang = languageHintForLayoutID(candidateTargetID)
            let fullMapped = characterMapper.convert(
                text: token.rawText,
                fromSourceID: currentID,
                toSourceID: candidateTargetID
            )
            let coreMapped = characterMapper.convert(
                text: token.core,
                fromSourceID: currentID,
                toSourceID: candidateTargetID
            )
            guard fullMapped != token.rawText || coreMapped != token.core else { continue }

            let fullMappedCore = BufferedToken(rawText: fullMapped, keyCodes: []).core
            let fullScore = scorer.score(fullMappedCore, expecting: mappedLang)
            let coreScore = scorer.score(coreMapped, expecting: mappedLang)
            let decision: LayoutInterpretationDecision
            if token.leadingEdge.isEmpty && token.trailingEdge.isEmpty {
                decision = LayoutInterpretationPolicy.select(
                    token: token,
                    fullMapped: fullMapped,
                    coreMapped: coreMapped,
                    fullIsValid: true,
                    coreIsValid: true,
                    boundary: boundary
                )
            } else {
                let fullIsWord = !fullMappedCore.isEmpty
                    && AutoFixDecision.isCorrectlySpelled(fullMappedCore, language: mappedLang)
                let coreIsWord = !coreMapped.isEmpty
                    && AutoFixDecision.isCorrectlySpelled(coreMapped, language: mappedLang)
                let fullIsValid: Bool
                let coreIsValid: Bool
                if fullIsWord != coreIsWord {
                    fullIsValid = fullIsWord
                    coreIsValid = coreIsWord
                } else {
                    fullIsValid = fullIsWord || AutoFixDecision.shouldReplace(
                        scoreOriginal: scoreOriginal,
                        scoreCandidate: fullScore,
                        threshold: threshold
                    )
                    coreIsValid = coreIsWord || AutoFixDecision.shouldReplace(
                        scoreOriginal: scoreOriginal,
                        scoreCandidate: coreScore,
                        threshold: threshold
                    )
                }
                decision = LayoutInterpretationPolicy.select(
                    token: token,
                    fullMapped: fullMapped,
                    coreMapped: coreMapped,
                    fullIsValid: fullIsValid,
                    coreIsValid: coreIsValid,
                    boundary: boundary
                )
            }

            guard let selectedPlan = decision.replacementPlan ?? decision.suggestions.max(by: {
                let lhsScore = $0.interpretationReason == .layoutFullToken ? fullScore : coreScore
                let rhsScore = $1.interpretationReason == .layoutFullToken ? fullScore : coreScore
                return lhsScore < rhsScore
            }) else { continue }
            let selectedScore = selectedPlan.interpretationReason == .layoutFullToken ? fullScore : coreScore
            evaluatedCandidates.append(AutoFixTargetCandidate(
                targetID: candidateTargetID,
                targetLang: mappedLang,
                candidate: selectedPlan.renderedReplacement,
                scoreCandidate: selectedScore,
                replacementPlan: selectedPlan,
                isInterpretationAmbiguous: decision.isSuggestionOnly
            ))
        }

        guard let selection = AutoFixCandidateGenerator.select(
            candidates: evaluatedCandidates,
            scoreOriginal: scoreOriginal,
            threshold: threshold,
            separation: Defaults[.autoFixCandidateSeparation]
        ) else {
            logSkip(.identicalCandidate, word: word, bundleID: bundleID, layoutID: currentID)
            observeMistakeCandidate(word: word, language: currentLang, bundleID: bundleID)
            phraseBuffer.reset()
            return
        }

        let targetID = selection.best.targetID
        let targetLang = selection.best.targetLang
        let candidate = selection.best.candidate
        let scoreCandidate = selection.best.scoreCandidate
        let replacementPlan = selection.best.replacementPlan ?? token.replacementPlan(
            correctedCore: candidate,
            boundary: boundary,
            reason: .layoutCorePreservingEdges
        )
        let isAmbiguousTarget = selection.isAmbiguous || selection.best.isInterpretationAmbiguous

        if skipReason == .tooShort {
            logSkip(.tooShort, word: word, bundleID: bundleID, layoutID: currentID)
            _ = maybeApplyPhraseFix(
                plan: replacementPlan,
                assessment: phraseAssessment(
                    token: token,
                    plan: replacementPlan,
                    targetLayoutID: targetID,
                    sourceLanguage: currentLang,
                    targetLanguage: targetLang,
                    isAmbiguous: isAmbiguousTarget
                ),
                fromLayoutID: currentID,
                targetLayoutID: targetID,
                scorer: scorer,
                threshold: threshold,
                algorithm: algorithm,
                currentLang: currentLang,
                targetLang: targetLang,
                bundleID: bundleID,
                canMutateDirectly: canMutateDirectly,
                allowsProposal: appPolicy.allowsProposal,
                targetSession: targetSession
            )
            return
        }

        // Hard guard against false positives like `faster` -> `афіеук`. If the
        // original is a real word in the current layout's language, the user
        // intended to type it; never replace.
        if AutoFixDecision.isCorrectlySpelled(coreWord, language: currentLang) {
            logSkip(.originalIsRealWord, word: word, bundleID: bundleID, layoutID: currentID, extra: [
                "from_lang": .string(currentLang)
            ])
            phraseBuffer.reset()
            return
        }

        if Defaults[.autoFixSpellingTypoGuardEnabled] {
            let typoAssessment = AutoFixDecision.spellingTypoGuardAssessment(
                original: coreWord,
                candidate: replacementPlan.correctedCore,
                language: currentLang,
                minWordLength: Defaults[.autoFixSpellingTypoGuardMinWordLength],
                maxEditDistance: Defaults[.autoFixSpellingTypoGuardMaxEditDistance]
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
                phraseBuffer.reset()
                return
            }
        }

        let predictionAdjustment = ProtectedLexiconPredictionScorer.adjustment(
            original: coreWord,
            candidate: replacementPlan.correctedCore,
            scoreCandidate: scoreCandidate,
            threshold: threshold
        )
        let effectiveScoreCandidate = predictionAdjustment.adjustedCandidateScore
        let effectiveThreshold = predictionAdjustment.adjustedThreshold

        AppLogger.post(
            logger,
            "Eval word=\(word) -> \(candidate); scores: \(scoreOriginal) vs \(effectiveScoreCandidate); threshold=\(effectiveThreshold)"
        )

        let mixedDecision = AutoFixMixedLanguagePolicy.decision(
            original: coreWord,
            candidate: replacementPlan.correctedCore,
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
            phraseBuffer.reset()
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
            if maybeApplyPhraseFix(
                plan: replacementPlan,
                assessment: phraseAssessment(
                    token: token,
                    plan: replacementPlan,
                    targetLayoutID: targetID,
                    sourceLanguage: currentLang,
                    targetLanguage: targetLang,
                    isAmbiguous: isAmbiguousTarget
                ),
                fromLayoutID: currentID,
                targetLayoutID: targetID,
                scorer: scorer,
                threshold: threshold,
                algorithm: algorithm,
                currentLang: currentLang,
                targetLang: targetLang,
                bundleID: bundleID,
                canMutateDirectly: canMutateDirectly,
                allowsProposal: appPolicy.allowsProposal,
                targetSession: targetSession
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
                    canApplyDirectly: canMutateDirectly,
                    targetSession: targetSession,
                    plan: replacementPlan
                )
            }
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
                    canApplyDirectly: false,
                    targetSession: targetSession,
                    plan: replacementPlan,
                    force: true
                )
            } else {
                logSkip(.unsafeEditor, word: word, bundleID: bundleID, extra: [
                    "app_policy": .string(appPolicy.rawValue)
                ])
            }
            phraseBuffer.reset()
            return
        }

        phraseBuffer.reset()

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
                    canApplyDirectly: canMutateDirectly,
                    targetSession: targetSession,
                    plan: replacementPlan,
                    force: true
                )
            }
            return
        }

        applyFix(
            plan: replacementPlan,
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

    private func maybeApplyPhraseFix(
        plan: ReplacementPlan,
        assessment: PhraseTokenAssessment,
        fromLayoutID: String,
        targetLayoutID: String,
        scorer: LanguageScorer,
        threshold: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        bundleID: String,
        canMutateDirectly: Bool,
        allowsProposal: Bool,
        targetSession: AutoFixTargetSession?
    ) -> Bool {
        guard plan.boundary == " ",
              case .layoutCandidate(let assessedTargetID) = assessment,
              assessedTargetID == targetLayoutID else {
            phraseBuffer.reset()
            return false
        }

        phraseBuffer.append(plan: plan, assessment: assessment, targetLayoutID: targetLayoutID)
        guard phraseBuffer.wordCount >= 3 else { return false }
        guard PhraseLayoutPolicy.unanimousTarget(in: phraseBuffer.assessments) == targetLayoutID else {
            phraseBuffer.reset()
            return false
        }

        let originalBody = phraseBuffer.originalBody
        let candidateBody = phraseBuffer.candidateBody
        let phrasePlan = ReplacementPlan(
            rawSource: originalBody,
            correctedCore: candidateBody,
            preservedLeadingPunctuation: "",
            preservedTrailingPunctuation: "",
            renderedReplacement: candidateBody,
            boundary: phraseBuffer.trailingBoundary,
            interpretationReason: .phrase
        )
        guard originalBody != candidateBody else {
            phraseBuffer.reset()
            return false
        }

        if AutoFixDecision.shouldSuppressPhraseAutoReplace(
            original: originalBody,
            candidate: candidateBody,
            sourceLanguage: currentLang,
            targetLanguage: targetLang,
            allowlist: Defaults[.autoFixAllowlist]
        ) {
            logSkip(.originalIsRealWord, word: originalBody, bundleID: bundleID, layoutID: fromLayoutID, extra: [
                "from_lang": .string(currentLang),
                "to_lang": .string(targetLang),
                "source": .string("phrase_source_guard")
            ])
            phraseBuffer.reset()
            return true
        }

        let scoreOriginal = scorer.score(originalBody, expecting: currentLang)
        let scoreCandidate = scorer.score(candidateBody, expecting: targetLang)
        AppLogger.post(
            logger,
            "Phrase eval=\(originalBody) -> \(candidateBody); scores: \(scoreOriginal) vs \(scoreCandidate); threshold=\(threshold)"
        )

        let shouldReplace = AutoFixDecision.shouldReplace(
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            threshold: threshold
        )

        guard shouldReplace else {
            let shouldPropose = AutoFixProposalPolicy.shouldSuggest(
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: threshold,
                window: Defaults[.autoFixProposalWindow]
            ) || AutoFixDecision.shouldSuggestPhraseLayoutMistake(
                original: originalBody,
                candidate: candidateBody,
                targetLanguage: targetLang,
                scoreCandidate: scoreCandidate
            )
            guard allowsProposal, shouldPropose else {
                return false
            }

            maybeShowProposal(
                original: originalBody,
                candidate: candidateBody,
                boundary: phraseBuffer.trailingBoundary,
                fromLayoutID: fromLayoutID,
                targetLayoutID: targetLayoutID,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: threshold,
                algorithm: algorithm,
                currentLang: currentLang,
                targetLang: targetLang,
                bundleID: bundleID,
                canApplyDirectly: canMutateDirectly,
                targetSession: targetSession,
                plan: phrasePlan,
                force: true
            )
            phraseBuffer.reset()
            return true
        }

        guard canMutateDirectly else {
            guard allowsProposal else { return false }
            maybeShowProposal(
                original: originalBody,
                candidate: candidateBody,
                boundary: phraseBuffer.trailingBoundary,
                fromLayoutID: fromLayoutID,
                targetLayoutID: targetLayoutID,
                scoreOriginal: scoreOriginal,
                scoreCandidate: scoreCandidate,
                threshold: threshold,
                algorithm: algorithm,
                currentLang: currentLang,
                targetLang: targetLang,
                bundleID: bundleID,
                canApplyDirectly: false,
                targetSession: targetSession,
                plan: phrasePlan,
                force: true
            )
            phraseBuffer.reset()
            return true
        }

        applyPhraseFix(
            plan: phrasePlan,
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scoreOriginal: scoreOriginal,
            scoreCandidate: scoreCandidate,
            algorithm: algorithm,
            currentLang: currentLang,
            targetLang: targetLang,
            bundleID: bundleID,
            targetSession: targetSession
        )
        phraseBuffer.reset()
        return true
    }

    private func phraseAssessment(
        token: BufferedToken,
        plan: ReplacementPlan,
        targetLayoutID: String,
        sourceLanguage: String,
        targetLanguage: String,
        isAmbiguous: Bool
    ) -> PhraseTokenAssessment {
        PhraseLayoutPolicy.assess(
            originalCore: token.core,
            correctedCore: plan.correctedCore,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            targetLayoutID: targetLayoutID,
            isAmbiguous: isAmbiguous
        )
    }

    private func applyPhraseFix(
        plan: ReplacementPlan,
        fromLayoutID: String,
        targetLayoutID: String,
        scoreOriginal: Double,
        scoreCandidate: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) {
        guard mutationIsStillSafe(targetSession: targetSession, bundleID: bundleID, word: plan.rawSource) else {
            return
        }
        AppLogger.action(logger, "Auto-fix phrase applying: \(plan.rawSource) -> \(plan.renderedReplacement)")
        AutoFixProposalCoordinator.shared.dismiss()
        deleteCharacters(count: plan.characterCountToDelete)
        typeText(plan.textToType)
        switchLayoutIfNeeded(
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scope: .phrase
        )

        lastFix = PendingUndo(
            original: plan.rawSource,
            replacement: plan.renderedReplacement,
            boundary: plan.boundaryToReplay,
            fromLayoutID: fromLayoutID,
            timestamp: ProcessInfo.processInfo.systemUptime,
            targetSession: targetSession
        )

        AnalyticsCounters.recordReplacement(text: plan.renderedReplacement)
        NotificationCenter.default.post(name: .textReplacementDidComplete, object: nil)

        if Defaults[.autoFixToastEnabled] {
            FixToastCoordinator.shared.show(near: NSEvent.mouseLocation) { [weak self] in
                self?.undoAndAddToAllowlist()
            }
        }

        PapugaEventLog.shared.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixApplied,
            frontmostBundleID: bundleID,
            inputLayout: targetLayoutID,
            properties: [
                "original_length": .int(plan.rawSource.count),
                "replacement_length": .int(plan.renderedReplacement.count),
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
                original: plan.rawSource,
                converted: plan.renderedReplacement,
                sourceLayoutID: fromLayoutID,
                targetLayoutID: targetLayoutID,
                bundleID: bundleID
            )
        )
    }

    private func applyFix(
        plan: ReplacementPlan,
        fromLayoutID: String,
        targetLayoutID: String,
        scoreOriginal: Double,
        scoreCandidate: Double,
        algorithm: LanguageScorerAlgorithm,
        currentLang: String,
        targetLang: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) {
        guard mutationIsStillSafe(targetSession: targetSession, bundleID: bundleID, word: plan.rawSource) else {
            return
        }
        AppLogger.action(logger, "Auto-fix applying: \(plan.rawSource) -> \(plan.renderedReplacement)")
        // Word + boundary char already typed. Delete the original word and the
        // boundary, then re-type the candidate followed by the same boundary so
        // Enter/Tab keep their semantics (newline, focus shift, indent).
        let boundaryToReplay = plan.boundaryToReplay
        deleteCharacters(count: plan.characterCountToDelete)
        typeText(plan.textToType)
        switchLayoutIfNeeded(
            fromLayoutID: fromLayoutID,
            targetLayoutID: targetLayoutID,
            scope: .singleToken
        )

        lastFix = PendingUndo(
            original: plan.rawSource,
            replacement: plan.renderedReplacement,
            boundary: boundaryToReplay,
            fromLayoutID: fromLayoutID,
            timestamp: ProcessInfo.processInfo.systemUptime,
            targetSession: targetSession
        )

        AnalyticsCounters.recordReplacement(text: plan.renderedReplacement)
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
                "original_length": .int(plan.rawSource.count),
                "replacement_length": .int(plan.renderedReplacement.count),
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
                original: plan.rawSource,
                converted: plan.renderedReplacement,
                sourceLayoutID: fromLayoutID,
                targetLayoutID: targetLayoutID,
                bundleID: bundleID
            )
        )
    }

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
        canApplyDirectly: Bool,
        targetSession: AutoFixTargetSession?,
        plan: ReplacementPlan? = nil,
        force: Bool = false
    ) {
        guard Defaults[.autoFixProposalEnabled] else { return }
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
            guard shouldSuggestNearThreshold || shouldSuggestLayoutMistake else { return }
        }

        let boundaryToReplay = boundary.isEmpty ? " " : boundary
        let replacementPlan = plan ?? ReplacementPlan(
            rawSource: original,
            correctedCore: candidate,
            preservedLeadingPunctuation: "",
            preservedTrailingPunctuation: "",
            renderedReplacement: candidate,
            boundary: boundaryToReplay,
            interpretationReason: original.contains(where: \.isWhitespace) ? .phrase : .layoutFullToken
        )
        let proposal = AutoFixProposal(
            original: original,
            candidate: candidate,
            boundary: boundaryToReplay,
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
            canApplyDirectly: canApplyDirectly,
            targetSession: targetSession,
            replacementPlan: replacementPlan
        )

        AutoFixProposalCoordinator.shared.show(
            proposal: proposal,
            near: NSEvent.mouseLocation,
            actions: AutoFixProposalActions(
                replace: { [weak self] in
                    guard let self else { return }
                    let canCreateRule = self.canCreateRule(from: proposal)
                    let historyKind: ReplacementHistoryEntry.Kind = canCreateRule ? .autoRuleApplied : .autoFixApplied
                    if self.applyProposal(
                        proposal,
                        source: canCreateRule ? "proposal_auto_rule" : "proposal",
                        historyKind: historyKind
                    ), canCreateRule {
                        self.createRuleFromProposal(proposal)
                    }
                },
                ignore: { [weak self] in
                    self?.ignoreProposal(proposal)
                }
            )
        )
    }

    private func showRuleProposal(
        rule: CustomAutoReplaceRule,
        plan: ReplacementPlan,
        fromLayoutID: String,
        bundleID: String,
        targetSession: AutoFixTargetSession?,
        canApplyDirectly: Bool
    ) {
        let proposal = AutoFixProposal(
            original: plan.rawSource,
            candidate: plan.renderedReplacement,
            boundary: plan.boundary.isEmpty ? " " : plan.boundary,
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
            canApplyDirectly: canApplyDirectly,
            targetSession: targetSession,
            replacementPlan: plan
        )

        AutoFixProposalCoordinator.shared.show(
            proposal: proposal,
            near: NSEvent.mouseLocation,
            actions: AutoFixProposalActions(
                replace: { [weak self] in
                    _ = self?.applyProposal(proposal, source: "custom_rule_proposal", historyKind: .autoRuleApplied)
                },
                ignore: { [weak self] in
                    self?.ignoreProposal(proposal)
                }
            )
        )
    }

    @discardableResult
    private func applyProposal(
        _ proposal: AutoFixProposal,
        source: String,
        historyKind: ReplacementHistoryEntry.Kind = .autoFixApplied
    ) -> Bool {
        let policy = AutoFixAppPolicyResolver.policy(for: proposal.bundleID)
        guard mutationIsStillSafe(
            targetSession: proposal.targetSession,
            bundleID: proposal.bundleID,
            word: proposal.original,
            allowUnverifiableInFrontmostApp: policy == .suggestOnly || !proposal.canApplyDirectly
        ) else {
            return false
        }
        let plan = proposal.replacementPlan
        AppLogger.action(logger, "AutoFix proposal accepted: \(plan.rawSource) -> \(plan.renderedReplacement)")
        phraseBuffer.reset()
        deleteCharacters(count: plan.characterCountToDelete)
        typeText(plan.textToType)
        let replacementScope: ReplacementScope = plan.rawSource.contains(where: \.isWhitespace) ? .phrase : .singleToken
        switchLayoutIfNeeded(
            fromLayoutID: proposal.fromLayoutID,
            targetLayoutID: proposal.targetLayoutID,
            scope: replacementScope
        )

        lastFix = PendingUndo(
            original: plan.rawSource,
            replacement: plan.renderedReplacement,
            boundary: plan.boundaryToReplay,
            fromLayoutID: proposal.fromLayoutID,
            timestamp: ProcessInfo.processInfo.systemUptime,
            targetSession: proposal.targetSession
        )

        AnalyticsCounters.recordReplacement(text: plan.renderedReplacement)
        NotificationCenter.default.post(name: .textReplacementDidComplete, object: nil)

        if Defaults[.autoFixToastEnabled] {
            FixToastCoordinator.shared.show(near: NSEvent.mouseLocation) { [weak self] in
                self?.undoAndAddToAllowlist()
            }
        }

        PapugaEventLog.shared.track(AnalyticsEvent(
            kind: AnalyticsKind.autoFixApplied,
            frontmostBundleID: proposal.bundleID,
            inputLayout: proposal.targetLayoutID,
            properties: [
                "original_length": .int(plan.rawSource.count),
                "replacement_length": .int(plan.renderedReplacement.count),
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
                original: plan.rawSource,
                converted: plan.renderedReplacement,
                sourceLayoutID: proposal.fromLayoutID,
                targetLayoutID: proposal.targetLayoutID,
                bundleID: proposal.bundleID
            )
        )
        return true
    }

    private func createRuleFromProposal(_ proposal: AutoFixProposal) {
        guard canCreateRule(from: proposal) else { return }
        let source = BufferedToken.normalizedCore(from: proposal.original)
        let target = BufferedToken.normalizedCore(from: proposal.replacementPlan.correctedCore)
        var rules = Defaults[.customAutoReplaceRules]
        rules.removeAll {
            BufferedToken.normalizedCore(from: $0.source).caseInsensitiveCompare(source) == .orderedSame
        }
        rules.append(CustomAutoReplaceRule(
            source: source,
            target: target,
            createdFromRecommendation: true
        ))
        Defaults[.customAutoReplaceRules] = rules
        cachedCustomRules = rules

        var allowlist = Defaults[.autoFixAllowlist]
        allowlist.removeAll {
            BufferedToken.normalizedCore(from: $0).caseInsensitiveCompare(source) == .orderedSame
        }
        Defaults[.autoFixAllowlist] = allowlist
    }

    private func canCreateRule(from proposal: AutoFixProposal) -> Bool {
        let sourceToken = BufferedToken(rawText: proposal.original, keyCodes: [])
        let targetToken = BufferedToken(rawText: proposal.candidate, keyCodes: [])
        let source = sourceToken.core
        let target = targetToken.core
        return !source.isEmpty
            && !target.isEmpty
            && !source.contains(where: \.isWhitespace)
            && !target.contains(where: \.isWhitespace)
            && !(proposal.replacementPlan.interpretationReason == .layoutFullToken
                && (!sourceToken.leadingEdge.isEmpty || !sourceToken.trailingEdge.isEmpty))
    }

    private func ignoreProposal(_ proposal: AutoFixProposal) {
        IgnoreWordService.add(proposal.original)
        cachedCustomRules = Defaults[.customAutoReplaceRules]
        sessionRejected.insert(BufferedToken(rawText: proposal.original, keyCodes: []).core)
    }

    private func applyCustomRule(
        rule: CustomAutoReplaceRule,
        plan: ReplacementPlan,
        bundleID: String,
        targetSession: AutoFixTargetSession?
    ) {
        guard mutationIsStillSafe(targetSession: targetSession, bundleID: bundleID, word: plan.rawSource) else {
            return
        }
        AppLogger.action(logger, "Custom rule applying: \(rule.source) -> \(rule.target)")
        let fromLayoutID = layoutManager.getCurrentLayoutID()
        let boundaryToReplay = plan.boundaryToReplay
        deleteCharacters(count: plan.characterCountToDelete)
        typeText(plan.textToType)

        lastFix = PendingUndo(
            original: plan.rawSource,
            replacement: plan.renderedReplacement,
            boundary: boundaryToReplay,
            fromLayoutID: fromLayoutID,
            timestamp: ProcessInfo.processInfo.systemUptime,
            targetSession: targetSession
        )

        AnalyticsCounters.recordReplacement(text: plan.renderedReplacement)
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
                "original_length": .int(plan.rawSource.count),
                "replacement_length": .int(plan.renderedReplacement.count),
                "rule_origin": .string(rule.createdFromRecommendation ? "recommendation" : "manual"),
                "source": .string("custom_rule")
            ]
        ))

        ReplacementHistoryStore.shared.record(
            ReplacementHistoryEntry(
                kind: .autoRuleApplied,
                original: plan.rawSource,
                converted: plan.renderedReplacement,
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
        layoutID: String? = nil,
        extra: [String: AnalyticsValue] = [:]
    ) {
        AppLogger.post(logger, "auto-fix skipped: reason=\(reason.rawValue) word=\(word)")
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

    private func mutationIsStillSafe(
        targetSession: AutoFixTargetSession?,
        bundleID: String,
        word: String,
        allowUnverifiableInFrontmostApp: Bool = false
    ) -> Bool {
        let activeBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let targetSession else {
            if allowUnverifiableInFrontmostApp,
               !bundleID.isEmpty,
               activeBundleID == bundleID {
                AppLogger.warn(
                    logger,
                    "Allowing explicit proposal accept with missing target session in frontmost app"
                )
                return true
            }
            logSkip(.targetUnverifiable, word: word, bundleID: bundleID, extra: [
                "target_reason": .string("missing_session")
            ])
            return false
        }

        let validation = targetValidator.validateCurrentTarget(
            for: targetSession,
            expectedBundleID: bundleID
        )

        switch validation {
        case .verified:
            return true
        case .changed(let reason):
            logSkip(.targetChanged, word: word, bundleID: bundleID, extra: [
                "target_reason": .string(reason)
            ])
            return false
        case .unverifiable(let reason):
            if allowUnverifiableInFrontmostApp,
               !bundleID.isEmpty,
               activeBundleID == bundleID {
                AppLogger.warn(
                    logger,
                    "Allowing explicit proposal accept with unverifiable target in frontmost app: \(reason)"
                )
                return true
            }
            logSkip(.targetUnverifiable, word: word, bundleID: bundleID, extra: [
                "target_reason": .string(reason)
            ])
            return false
        }
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

    private func deleteCharacters(count: Int) {
        guard count > 0 else { return }
        let source = syntheticEventSource
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Delete), keyDown: true)
            down?.post(tap: .cgAnnotatedSessionEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_Delete), keyDown: false)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func typeText(_ text: String) {
        let source = syntheticEventSource
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

    var token: BufferedToken {
        BufferedToken(rawText: text, keyCodes: keyCodes)
    }

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

private struct PhraseBuffer {
    private struct Token {
        let plan: ReplacementPlan
        let assessment: PhraseTokenAssessment
    }

    private let maxWords: Int
    private var tokens: [Token] = []
    /// The target layout the buffered tokens convert to. If a later word resolves to a different
    /// target, the accumulated phrase would mix scripts, so we restart the buffer.
    private(set) var targetLayoutID: String?

    init(maxWords: Int) {
        self.maxWords = maxWords
    }

    var wordCount: Int {
        tokens.count
    }

    var trailingBoundary: String {
        tokens.last?.plan.boundary ?? " "
    }

    var assessments: [PhraseTokenAssessment] {
        tokens.map(\.assessment)
    }

    var originalBody: String {
        body(\.rawSource)
    }

    var candidateBody: String {
        body(\.renderedReplacement)
    }

    mutating func append(
        plan: ReplacementPlan,
        assessment: PhraseTokenAssessment,
        targetLayoutID: String
    ) {
        if let existing = self.targetLayoutID, existing != targetLayoutID {
            reset()
        }
        self.targetLayoutID = targetLayoutID
        tokens.append(Token(plan: plan, assessment: assessment))
        if tokens.count > maxWords {
            tokens.removeFirst(tokens.count - maxWords)
        }
    }

    mutating func reset() {
        tokens.removeAll()
        targetLayoutID = nil
    }

    private func body(_ keyPath: KeyPath<ReplacementPlan, String>) -> String {
        tokens.enumerated().map { index, token in
            let text = token.plan[keyPath: keyPath]
            guard index < tokens.count - 1 else { return text }
            return text + token.plan.boundary
        }.joined()
    }
}

private struct PendingUndo {
    let original: String
    let replacement: String
    let boundary: String
    let fromLayoutID: String
    let timestamp: TimeInterval
    let targetSession: AutoFixTargetSession?
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
