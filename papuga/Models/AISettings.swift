import Defaults
import Foundation

/// How Papuga obtains AI classifications for the "Покращити з AI" flow.
/// `paste` (bring-your-own ChatGPT/Claude) is the only mode wired up today; the others
/// are declared so the settings UI and storage are stable as they come online.
enum AIProvider: String, CaseIterable, Identifiable, Defaults.Serializable {
    case paste
    case ollama
    case openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: return "Вставити вручну (ChatGPT / Claude)"
        case .ollama: return "Локальна модель (Ollama)"
        case .openRouter: return "OpenRouter (свій ключ)"
        }
    }

    var subtitle: String {
        switch self {
        case .paste: return "Без налаштувань: копіюєш промт у свій ШІ, вставляєш відповідь назад."
        case .ollama: return "Працює офлайн на твоєму Mac. Нічого не йде в інтернет."
        case .openRouter: return "Хмарні моделі через твій API-ключ. Ключ зберігається локально."
        }
    }

    /// Only paste mode is functional right now; the rest render disabled with «скоро».
    var isAvailable: Bool { self == .paste }
}

extension Defaults.Keys {
    /// Selected `AIProvider` raw value.
    static let aiProvider = Key<String>("aiProvider", default: AIProvider.paste.rawValue)
    /// Code-enforced consent gate — words only leave the device once this is true. App is
    /// unsandboxed, so this boolean is the single barrier (AI-ASSIST.md §8.1). Default false.
    static let aiConsentGranted = Key<Bool>("aiConsentGranted", default: false)
    /// Strip likely secrets/PII from the prompt before sending. Default ON (AI-ASSIST.md §8.2).
    static let aiSecretScrubbing = Key<Bool>("aiSecretScrubbing", default: true)
    /// Include the originating app names as hints in the prompt.
    static let aiSendAppNames = Key<Bool>("aiSendAppNames", default: true)
    /// Preferred OpenRouter model id (used once that provider ships).
    static let openRouterModel = Key<String>("openRouterModel", default: "google/gemini-2.5-flash-lite")
}
