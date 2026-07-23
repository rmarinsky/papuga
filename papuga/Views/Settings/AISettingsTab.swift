import Defaults
import SwiftUI

/// "AI" settings: how the "Покращити з ШІ" flow gets classifications, plus the privacy
/// switches that gate it. Consent is OFF by default and the secret scrubber is ON by
/// default (AI-ASSIST.md §8). Only paste mode is functional today.
struct AISettingsTab: View {
    @Default(.aiProvider) private var providerRaw
    @Default(.aiConsentGranted) private var consentGranted
    @Default(.aiSecretScrubbing) private var secretScrubbing
    @Default(.aiSendAppNames) private var sendAppNames
    @Default(.openRouterModel) private var openRouterModel

    private var selectedProvider: AIProvider { AIProvider(rawValue: providerRaw) ?? .paste }

    var body: some View {
        Form {
            Section {
                ForEach(AIProvider.allCases) { provider in
                    providerRow(provider)
                }
            } header: {
                Text("Спосіб")
            } footer: {
                Text("«Покращити з ШІ» бере твій штучний інтелект і класифікує рідкісні помилки, які прості правила не ловлять. Відкривається у вкладці «Помилки введення» кнопкою «Покращити з ШІ».")
            }

            if selectedProvider == .openRouter {
                Section("OpenRouter") {
                    TextField("Модель", text: $openRouterModel)
                        .disabled(true)
                    Text("Ключ зберігатиметься у Keychain. З'явиться у наступному оновленні.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Дозволити надсилати слова моєму ШІ", isOn: $consentGranted)
                Text(consentGranted
                     ? "Увімкнено. Для режиму «вставити» слова потрапляють у буфер обміну, коли копіюєш промт."
                     : "Вимкнено. Без цього дозволу жодне слово не покидає пристрій.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Прибирати схожі на секрети слова", isOn: $secretScrubbing)
                Text("Паролі, ключі, email, посилання й довгі випадкові рядки не потраплять у промт.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Додавати назви застосунків як підказку", isOn: $sendAppNames)
            } header: {
                Text("Приватність")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func providerRow(_ provider: AIProvider) -> some View {
        Button {
            if provider.isAvailable { providerRaw = provider.rawValue }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selectedProvider == provider ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selectedProvider == provider ? Color("BrandAccentDeep") : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        if !provider.isAvailable {
                            Text("скоро")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                    Text(provider.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .opacity(provider.isAvailable ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!provider.isAvailable)
    }
}
