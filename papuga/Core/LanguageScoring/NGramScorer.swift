import Foundation

struct NGramScorer: LanguageScorer {
    func score(_ text: String, expecting languageCode: String) -> Double {
        // Stub: pruned char-trigram naive-Bayes model per Vatanen et al. (LREC 2010,
        // https://aclanthology.org/L10-1193/) is not yet bundled.
        // Falls back to AppleNLScorer so settings choosing this algorithm don't blank out.
        return AppleNLScorer().score(text, expecting: languageCode)
    }
}
