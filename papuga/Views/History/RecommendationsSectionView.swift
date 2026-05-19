import Defaults
import SwiftUI

struct RecommendationsSectionView: View {
    let recommendations: [Recommendation]

    @Default(.autoFixAllowlist) private var autoFixAllowlist
    @Default(.autoFixBlocklist) private var autoFixBlocklist
    @Default(.customAutoReplaceRules) private var customAutoReplaceRules
    @Default(.dismissedRecommendations) private var dismissedRecommendations

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerCaption

                if recommendations.isEmpty {
                    emptyView
                } else {
                    ForEach(recommendations) { rec in
                        RecommendationCard(
                            recommendation: rec,
                            onAccept: { accept(rec) },
                            onDismiss: { dismiss(rec) }
                        )
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var headerCaption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Розумні поради")
                .font(.title3.weight(.semibold))
            Text("Аналізуємо твою історію за порогами 3 → 5 → 8 → 13 → 21 повторень. Сильніший рівень — більш термінова порада.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Поки що жодних порад")
                .font(.headline)
            Text("Як тільки накопичиться достатньо однакових подій, тут з'являться рекомендації.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func accept(_ rec: Recommendation) {
        switch rec {
        case .addWordToAllowlist(let word, _, _):
            if !autoFixAllowlist.contains(where: { $0.lowercased() == word.lowercased() }) {
                autoFixAllowlist.append(word)
            }
        case .createCustomRule(let source, let target, _, _):
            if !customAutoReplaceRules.contains(where: {
                $0.source.lowercased() == source.lowercased()
            }) {
                customAutoReplaceRules.append(
                    CustomAutoReplaceRule(
                        source: source,
                        target: target,
                        createdFromRecommendation: true
                    )
                )
            }
        case .addAppToBlocklist(let bundleID, _, _):
            let normalized = bundleID.lowercased()
            if !autoFixBlocklist.contains(where: { $0.lowercased() == normalized }) {
                autoFixBlocklist.append(normalized)
            }
        }
        if !dismissedRecommendations.contains(rec.dedupKey) {
            dismissedRecommendations.append(rec.dedupKey)
        }
    }

    private func dismiss(_ rec: Recommendation) {
        if !dismissedRecommendations.contains(rec.dedupKey) {
            dismissedRecommendations.append(rec.dedupKey)
        }
    }
}

private struct RecommendationCard: View {
    let recommendation: Recommendation
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                tierBadge
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button(action: onAccept) {
                    Label(acceptTitle, systemImage: acceptIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button(role: .cancel, action: onDismiss) {
                    Text("Відхилити")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.windowBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2))
        )
    }

    private var tierBadge: some View {
        Text("\(recommendation.tier)")
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(tierColor))
            .accessibilityLabel("Рівень \(recommendation.tier)")
    }

    private var tierColor: Color {
        switch recommendation.tier {
        case 5: return .red
        case 4: return .orange
        case 3: return .yellow
        case 2: return .blue
        default: return .gray
        }
    }

    private var title: String {
        switch recommendation {
        case .addWordToAllowlist(let word, _, _):
            return "Додати «\(word)» у allowlist"
        case .createCustomRule(let source, let target, _, _):
            return "Додати правило: \(source) → \(target)"
        case .addAppToBlocklist(let bundleID, _, _):
            return "Вимкнути автозаміну у \(bundleID)"
        }
    }

    private var subtitle: String {
        switch recommendation {
        case .addWordToAllowlist(_, let n, _):
            return "AutoFix скасовувалася \(n) \(pluralizeTimes(n)). Папуга більше не чіпатиме це слово."
        case .createCustomRule(let source, let target, let n, _):
            return "Ти вже \(n) \(pluralizeTimes(n)) ручно конвертував «\(source)» у «\(target)». Зроби це автоматичним."
        case .addAppToBlocklist(_, let n, _):
            return "У цьому застосунку було \(n) скасованих автозамін. Імовірно, краще його виключити."
        }
    }

    private var acceptTitle: String {
        switch recommendation {
        case .addWordToAllowlist: return "Додати у allowlist"
        case .createCustomRule: return "Створити правило"
        case .addAppToBlocklist: return "Додати у blocklist"
        }
    }

    private var acceptIcon: String {
        switch recommendation {
        case .addWordToAllowlist: return "checkmark.shield"
        case .createCustomRule: return "wand.and.rays"
        case .addAppToBlocklist: return "app.badge.checkmark"
        }
    }

    private func pluralizeTimes(_ n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "раз" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "рази" }
        return "разів"
    }
}
