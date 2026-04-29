import Foundation
import NaturalLanguage

struct AppleNLScorer: LanguageScorer {
    func score(_ text: String, expecting languageCode: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let target = NLLanguage(languageCode)
        return hypotheses[target] ?? 0
    }
}
