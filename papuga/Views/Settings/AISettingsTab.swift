import AppKit
import Defaults
import SwiftUI

struct AISettingsTab: View {
    @Default(.aiAnalysisTargets) private var targets
    @Default(.aiConsentGranted) private var consentGranted
    @Default(.aiSecretScrubbing) private var secretScrubbing
    @Default(.aiSendAppNames) private var sendAppNames
    @State private var states: [AIProvider: AIProviderState] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(AIProvider.allCases) { provider in providerRow(provider) }
            } header: {
                Text("Моделі · обрано \(targets.count) з 3")
            } footer: {
                Text("Агенти отримують однакові локальні кандидати й лише пропонують результат. Жодна дія не застосовується автоматично.")
            }

            if targets.isEmpty {
                Section("Немає встановленого агента") {
                    Text("Встанови агент з офіційного сайту або скопіюй prompt і використай будь-який чат вручну.")
                        .foregroundStyle(.secondary)
                    ForEach(AIProvider.allCases) { provider in
                        HStack {
                            Text(provider.installCommand).font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button("Copy command") { copy(provider.installCommand) }
                            Link("Open official guide", destination: provider.guideURL)
                        }
                    }
                }
            }

            Section("Приватність") {
                Toggle("Дозволити надсилати слова моєму ШІ", isOn: $consentGranted)
                Toggle("Прибирати схожі на секрети слова", isOn: $secretScrubbing)
                Toggle("Додавати назви застосунків як підказку", isOn: $sendAppNames)
                Text("Raw prompts і responses існують лише доки відкрите порівняння. Manual copy/paste завжди доступний.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refreshStates() }
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        let selected = targets.contains { $0.provider == provider }
        return Button {
            if selected {
                targets.removeAll { $0.provider == provider }
            } else if targets.count < AIAnalysisSelection.maximum {
                targets = AIAnalysisSelection.normalized(targets + [AIAnalysisTarget(provider: provider, model: nil)])
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color("BrandAccentDeep") : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title).font(.system(size: 13, weight: .medium))
                    Text(statusText(provider)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selected && targets.count >= AIAnalysisSelection.maximum)
    }

    private func statusText(_ provider: AIProvider) -> String {
        guard provider != .ollama else { return "Локальна модель через localhost" }
        switch states[provider] {
        case .ready(_, let version): return version
        case .needsAuthentication: return "Потрібна авторизація"
        case .notInstalled: return "Не встановлено"
        case .failed(let message): return message
        case nil: return "Перевіряється…"
        }
    }

    private func refreshStates() async {
        for provider in AIProvider.allCases where provider != .ollama {
            let target = targets.first { $0.provider == provider } ?? AIAnalysisTarget(provider: provider, model: nil)
            states[provider] = await AIProviderDiscovery().probe(target)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private extension AIProvider {
    var installCommand: String {
        switch self {
        case .codex: return "npm install -g @openai/codex"
        case .claudeCode: return "npm install -g @anthropic-ai/claude-code"
        case .cursorAgent: return "curl https://cursor.com/install -fsS | bash"
        case .openCode: return "curl -fsSL https://opencode.ai/install | bash"
        case .ollama: return "Download Ollama.dmg"
        }
    }

    var guideURL: URL {
        switch self {
        case .codex: return URL(string: "https://developers.openai.com/codex/cli")!
        case .claudeCode: return URL(string: "https://docs.anthropic.com/en/docs/claude-code/getting-started")!
        case .cursorAgent: return URL(string: "https://docs.cursor.com/en/cli/installation")!
        case .openCode: return URL(string: "https://opencode.ai/docs/")!
        case .ollama: return URL(string: "https://docs.ollama.com/macos")!
        }
    }
}
