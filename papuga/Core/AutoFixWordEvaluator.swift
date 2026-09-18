import Carbon.HIToolbox
import Foundation

/// The synchronous production decision for one completed token. OS focus, editor mutation,
/// and phrase timing belong to the controller; mapping, dictionaries, and safety gates live here.
struct AutoFixWordEvaluation {
    enum Disposition: Equatable {
        case keep(AutoFixSkipReason)
        case sourceWord
        case shortWord
        case uncertain
        case suggestLayout
        case suggestSpelling(SpellingTypoGuardAssessment)
        case suggestCompound(String)
        case replace
    }

    let disposition: Disposition
    let scoreOriginal: Double
    let candidates: [AutoFixTargetCandidate]
    let selection: AutoFixCandidateGenerator.Selection?
    let effectiveScore: Double
    let threshold: Double

    var replacement: AutoFixTargetCandidate? {
        disposition == .replace ? selection?.best : nil
    }
}

struct AutoFixWordEvaluator {
    struct Configuration {
        var minimumLength = 2
        var threshold = 0.35
        var candidateSeparation = 0.15
        var spellingTypoGuardEnabled = true
        var spellingTypoGuardMinimumLength = 4
        var spellingTypoGuardMaximumDistance = 1
    }

    let mapper: CharacterMapper
    let spellChecker: SpellCheckingClient
    let scorer: LanguageScorer

    func evaluate(
        _ word: String,
        source: InputSourceInfo?,
        targets: [InputSourceInfo],
        configuration config: Configuration
    ) -> AutoFixWordEvaluation {
        var originalScore = 0.0
        var candidates: [AutoFixTargetCandidate] = []
        var selection: AutoFixCandidateGenerator.Selection?
        var effectiveScore = 0.0
        var threshold = config.threshold
        func result(_ disposition: AutoFixWordEvaluation.Disposition) -> AutoFixWordEvaluation {
            AutoFixWordEvaluation(disposition: disposition, scoreOriginal: originalScore,
                candidates: candidates, selection: selection, effectiveScore: effectiveScore, threshold: threshold)
        }

        if ProtectedLexiconStore.shared.match(word)?.protectsSource == true {
            return result(.keep(.mixedLanguageIntentional))
        }
        let skip = AutoFixDecision.shouldSkipWord(word, minLength: config.minimumLength)
        if skip == .containsDigits || skip == .containsForbiddenChars { return result(.keep(.containsDigits)) }
        guard !targets.isEmpty else { return result(.keep(.noTargetLayout)) }
        guard let source else { return result(.keep(.missingMaps)) }
        let currentLanguage = AutoFixDecision.languageHintForLayoutID(source.id)
        mapper.buildMap(for: source.source, sourceID: source.id)
        originalScore = scorer.score(word, expecting: currentLanguage)
        for target in targets {
            mapper.buildMap(for: target.source, sourceID: target.id)
            let language = AutoFixDecision.languageHintForLayoutID(target.id)
            var inner = word
            var leadingWrapper = "", trailingWrapper = ""
            let wrappers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "«": "»", "“": "”"]
            while inner.count > 2, let first = inner.first, let last = inner.last, wrappers[first] == last {
                leadingWrapper.append(first)
                trailingWrapper.insert(last, at: trailingWrapper.startIndex)
                inner = String(inner.dropFirst().dropLast())
            }
            let mapped = mapper.convert(text: inner, fromSourceID: source.id, toSourceID: target.id)
            guard mapped != inner else { continue }
            let token = BufferedToken(rawText: inner, keyCodes: [])
            let coreMapped = mapper.convert(text: token.core, fromSourceID: source.id, toSourceID: target.id)
            let fullValid = Self.isLexicalToken(mapped) && spellChecker.mappedSpellingStatus(mapped, language: language) == .correct
            let coreValid = Self.isLexicalToken(coreMapped) && spellChecker.mappedSpellingStatus(coreMapped, language: language) == .correct
            let interpretation = LayoutInterpretationPolicy.select(token: token,
                fullMapped: mapped, coreMapped: coreMapped, fullIsValid: fullValid, coreIsValid: coreValid, boundary: " ")
            var innerPlan = interpretation.suggestions.first
            var ambiguous = interpretation.isSuggestionOnly
            // Leading physical-letter keys (e.g. ];f -> їжа) are not English word punctuation.
            // For a trailing key, require a substantial frequency advantage to resolve two real words.
            if ambiguous && fullValid && (!token.leadingEdge.isEmpty ||
                spellChecker.logFrequency(of: mapped, language: language) - spellChecker.logFrequency(of: coreMapped, language: language) >= log10(4)) {
                ambiguous = false
            }
            if let chosen = innerPlan {
                innerPlan = ReplacementPlan(rawSource: word, correctedCore: chosen.correctedCore,
                    preservedLeadingPunctuation: leadingWrapper + chosen.preservedLeadingPunctuation,
                    preservedTrailingPunctuation: chosen.preservedTrailingPunctuation + trailingWrapper,
                    renderedReplacement: leadingWrapper + chosen.renderedReplacement + trailingWrapper,
                    boundary: " ", interpretationReason: chosen.interpretationReason)
            }
            candidates.append(AutoFixTargetCandidate(targetID: target.id, targetLang: language,
                candidate: innerPlan?.renderedReplacement ?? (leadingWrapper + mapped + trailingWrapper),
                scoreCandidate: scorer.score(innerPlan?.correctedCore ?? mapped, expecting: language),
                replacementPlan: innerPlan, isInterpretationAmbiguous: ambiguous))
        }
        // An unsupported target's language score cannot outrank an exact dictionary match.
        let attested = candidates.filter { $0.replacementPlan != nil }
        selection = AutoFixCandidateGenerator.select(candidates: attested.isEmpty ? candidates : attested,
            scoreOriginal: originalScore, threshold: threshold, separation: config.candidateSeparation)
        if let ranked = selection, !attested.isEmpty {
            let meanings = Set(attested.map { $0.targetLang + ":" + $0.candidate })
            selection = .init(best: ranked.best, runnerUp: ranked.runnerUp, isAmbiguous: meanings.count > 1)
        }
        guard let best = selection?.best else { return result(.keep(.identicalCandidate)) }
        effectiveScore = best.scoreCandidate
        if skip == .tooShort { return result(.shortWord) }
        let hasCore = !BufferedToken(rawText: word, keyCodes: []).core.isEmpty
        let sourceWord: String
        if let plan = best.replacementPlan {
            sourceWord = String(word.dropFirst(plan.preservedLeadingPunctuation.count).dropLast(plan.preservedTrailingPunctuation.count))
        } else {
            sourceWord = word
        }
        let lexicalCandidate = best.replacementPlan?.correctedCore ?? best.candidate
        // NSSpellChecker accepts consonant-only abbreviations such as yt, wt and vtys.
        // Only prefer a frequent cross-script word when the short lowercase source has
        // no English vowel and neither bundled nor learned vocabulary attests it.
        let isUnattestedAbbreviation = currentLanguage == "en"
            && (2...4).contains(sourceWord.count)
            && sourceWord.allSatisfy { ("a"..."z").contains(String($0)) }
            && !sourceWord.contains(where: { "aeiou".contains($0) })
            && !spellChecker.isExplicitlyKnown(sourceWord, language: currentLanguage)
            && spellChecker.logFrequency(of: lexicalCandidate, language: best.targetLang) >= 3
            && AutoFixDecision.isCrossScriptConversion(original: sourceWord, candidate: lexicalCandidate)
        if hasCore && Self.isLexicalToken(sourceWord) && !isUnattestedAbbreviation
            && !spellChecker.isMisspelled(sourceWord, language: currentLanguage) {
            return result(.sourceWord)
        }

        let spellingStatus = spellChecker.mappedSpellingStatus(lexicalCandidate, language: best.targetLang)
        if best.isInterpretationAmbiguous { return result(.suggestLayout) }
        switch AutoFixDecision.layoutReplacementGate(mappedSpellingStatus: spellingStatus,
            candidateIsWordLike: WordPlausibility.isWordLike(lexicalCandidate)) {
        case .requireProposal: return result(.suggestLayout)
        case .suppress:
            if spellingStatus == .misspelled,
               let suggestion = AutoFixDecision.compoundLayoutSpellingSuggestion(mapped: best.candidate,
                   targetLanguage: best.targetLang, isMisspelled: { _, _ in true },
                   guesses: { spellChecker.guesses(for: $0, language: $1) }) {
                return result(.suggestCompound(suggestion))
            }
            return result(.keep(.belowThreshold))
        case .allow: break
        }
        // A language score is not the probability that a word is spelled correctly.
        // Exact cross-script dictionary evidence remains useful even when AppleNL cannot
        // identify the language of a short, isolated word.
        let verifiedLayoutWord = spellingStatus == .correct
            && lexicalCandidate.count >= 2
            && WordPlausibility.isWordLike(lexicalCandidate)
            && AutoFixDecision.isCrossScriptConversion(original: word, candidate: best.candidate)
        // Only a plausible source-language token can be an ordinary spelling typo.
        // Stripping physical layout keys (e.g. lzre. -> lzre -> lure) invents a different word.
        if config.spellingTypoGuardEnabled && Self.isLexicalToken(word)
            && (!verifiedLayoutWord || originalScore >= 0.5) {
            let typo = AutoFixDecision.spellingTypoGuardAssessment(original: word, candidate: best.candidate,
                language: currentLanguage, minWordLength: config.spellingTypoGuardMinimumLength,
                maxEditDistance: config.spellingTypoGuardMaximumDistance,
                isKnownCorrect: { !spellChecker.isMisspelled($0, language: $1) },
                suggestions: { spellChecker.guesses(for: $0, language: $1) })
            if typo.shouldSuppressAutoReplace { return result(.suggestSpelling(typo)) }
        }
        let adjustment = ProtectedLexiconPredictionScorer.adjustment(original: word,
            candidate: best.candidate, scoreCandidate: best.scoreCandidate, threshold: threshold)
        effectiveScore = adjustment.adjustedCandidateScore
        threshold = adjustment.adjustedThreshold
        let mixed = AutoFixMixedLanguagePolicy.decision(original: word, candidate: best.candidate,
            currentLanguage: currentLanguage, targetLanguage: best.targetLang,
            scoreOriginal: originalScore, scoreCandidate: effectiveScore, threshold: threshold, verifiedLayoutWord: verifiedLayoutWord)
        if case .skipAsIntentional = mixed { return result(.keep(.mixedLanguageIntentional)) }
        guard verifiedLayoutWord || AutoFixDecision.shouldReplace(scoreOriginal: originalScore,
            scoreCandidate: effectiveScore, threshold: threshold) else { return result(.uncertain) }
        guard hasCore else { return result(.uncertain) }
        return result(selection?.isAmbiguous == true ? .suggestLayout : .replace)
    }
    private static func isLexicalToken(_ word: String) -> Bool {
        let pieces = word.split(omittingEmptySubsequences: false, whereSeparator: { "-'’ʼ".contains($0) })
        return !pieces.isEmpty && pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isLetter) }
    }

}
