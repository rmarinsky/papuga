import Foundation

protocol LanguageScorer {
    func score(_ text: String, expecting languageCode: String) -> Double
}
