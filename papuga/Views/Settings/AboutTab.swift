import SwiftUI
import Defaults

struct AboutTab: View {
    @ObservedObject private var updaterManager: UpdaterManager
    @Default(.textReplacementCount) private var textReplacementCount
    @Default(.customAutoReplaceRules) private var customRules
    @Default(.autoFixAllowlist) private var allowlist

    init() {
        self.updaterManager = AppDelegate.shared?.updaterManager ?? UpdaterManager()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                stats
                links
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color("BrandAccent"), Color("BrandAccentDeep")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "bird.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Constants.appName)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("PRO")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color("ProBadgeText"))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(Color("ProBadgeBg")))
                }

                Text(versionText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Text("Менюбар-утиліта, яка рятує текст, набраний не тією розкладкою.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Перевірити оновлення…") {
                updaterManager.checkForUpdates()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("BrandAccentDeep"))
            .disabled(!updaterManager.canCheckForUpdates)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color("BrandTintSoft"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color("BrandTintBorder"), lineWidth: 1)
        )
    }

    private var stats: some View {
        HStack(spacing: 12) {
            accountMetric(value: "\(textReplacementCount)", label: "замін")
            accountMetric(value: "\(customRules.count)", label: "власних правил")
            accountMetric(value: "\(allowlist.count)", label: "слів не чіпати")
        }
    }

    private func accountMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.tertiary)
        )
    }

    private var links: some View {
        SectionCard(eyebrow: "АККАУНТ", title: "Підтримка і релізи") {
            VStack(spacing: 10) {
                linkRow("Автор", value: "Roman Marinskyi", icon: "person")
                linkRow("GitHub", value: "rmarinsky/papuga", icon: "chevron.left.forwardslash.chevron.right")
                linkRow("Оновлення", value: "Sparkle appcast", icon: "arrow.triangle.2.circlepath")
            }
        }
    }

    private func linkRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color("BrandTintSoft"))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color("BrandAccentDeep"))
            }
            .frame(width: 26, height: 26)

            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var versionText: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
            return "Версія невідома"
        }
        return "Версія \(version) (\(build))"
    }
}
