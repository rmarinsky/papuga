import SwiftUI

struct RecommendationsSectionView: View {
    let recommendations: [Recommendation]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Папуга помітив ці патерни. Застосуй один — і далі він виправлятиме автоматично.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if recommendations.isEmpty {
                    emptyView
                } else {
                    ForEach(recommendations) { rec in
                        RecommendationCard(
                            recommendation: rec,
                            onAccept: { RecommendationEngine.apply(rec) },
                            onDismiss: { RecommendationEngine.dismiss(rec) }
                        )
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
}

private struct RecommendationCard: View {
    let recommendation: Recommendation
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconTile

            VStack(alignment: .leading, spacing: 3) {
                Text(recommendation.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(recommendation.displaySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(role: .cancel, action: onDismiss) {
                Text("Відхилити")
            }
            .buttonStyle(.bordered)

            Button(action: onAccept) {
                Text("Застосувати")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("BrandAccentDeep"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.tertiary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color("BrandTintBorder"), lineWidth: 1)
        )
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color("BrandTintSoft"))
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color("BrandAccentDeep"))
        }
        .frame(width: 30, height: 30)
    }

    private var icon: String {
        switch recommendation {
        case .addWordToAllowlist: return "checkmark.shield"
        case .createCustomRule: return "wand.and.rays"
        case .addAppToBlocklist: return "nosign"
        }
    }
}
