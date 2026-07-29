import Defaults
import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Codable, Defaults.Serializable {
    case codex
    case claudeCode
    case cursorAgent
    case openCode
    case ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .cursorAgent: return "Cursor Agent"
        case .openCode: return "OpenCode"
        case .ollama: return "Ollama"
        }
    }

    var executableName: String? {
        switch self {
        case .codex: return "codex"
        case .claudeCode: return "claude"
        case .cursorAgent: return "cursor-agent"
        case .openCode: return "opencode"
        case .ollama: return nil
        }
    }

    var generationArguments: [String] {
        switch self {
        case .codex: return ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-"]
        case .claudeCode:
            return ["-p", "--output-format", "text", "--no-session-persistence", "--permission-mode", "plan", "--tools", ""]
        case .cursorAgent: return ["-p", "--output-format", "text", "--mode", "ask"]
        case .openCode: return ["run"]
        case .ollama: return []
        }
    }

    var versionArguments: [String] { ["--version"] }

    var authArguments: [String]? {
        switch self {
        case .codex: return ["login", "status"]
        case .claudeCode: return ["auth", "status"]
        case .openCode: return ["auth", "list"]
        case .cursorAgent, .ollama: return nil
        }
    }
}

struct AIAnalysisTarget: Codable, Hashable, Defaults.Serializable, Identifiable {
    let provider: AIProvider
    var model: String?
    var executablePath: String?

    var id: String { "\(provider.rawValue)|\(model ?? "")" }
}

enum AIAnalysisSelection {
    static let maximum = 3

    static func normalized(_ targets: [AIAnalysisTarget]) -> [AIAnalysisTarget] {
        var seen = Set<String>()
        return targets.filter { seen.insert($0.id).inserted }.prefix(maximum).map { $0 }
    }
}

extension Defaults.Keys {
    /// Empty is the migration path from the retired manual `.paste` provider.
    static let aiAnalysisTargets = Key<[AIAnalysisTarget]>("aiAnalysisTargets", default: [])
    static let aiConsentGranted = Key<Bool>("aiConsentGranted", default: false)
    static let aiSecretScrubbing = Key<Bool>("aiSecretScrubbing", default: true)
    static let aiSendAppNames = Key<Bool>("aiSendAppNames", default: true)
}
