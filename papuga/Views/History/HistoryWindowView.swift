import Defaults
import KeyboardShortcuts
import SwiftUI

struct HistoryWindowView: View {
    @State private var selection: HistorySection
    @State private var historyStore = ReplacementHistoryStore.shared
    @State private var cachedRecommendations: [Recommendation] = []

    @Environment(LayoutManager.self) private var layoutManager
    @Environment(ClipboardHistoryManager.self) private var clipboardHistoryManager

    @Default(.autoFixAllowlist) private var autoFixAllowlist
    @Default(.autoFixBlocklist) private var autoFixBlocklist
    @Default(.customAutoReplaceRules) private var customAutoReplaceRules
    @Default(.dismissedRecommendations) private var dismissedRecommendations

    @Default(.isServiceRunning) private var isServiceRunning
    @Default(.useDoublePress) private var useDoublePress
    @Default(.doublePressShortcut) private var doublePressShortcut

    init(initialSection: HistorySection) {
        _selection = State(initialValue: initialSection)
    }

    private var recommendationCacheKey: String {
        "\(historyStore.entries.count)|\(autoFixAllowlist.joined())|\(autoFixBlocklist.joined())|\(customAutoReplaceRules.count)|\(dismissedRecommendations.joined())"
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detailView
        }
        .navigationTitle(selection.title)
        .task(id: recommendationCacheKey) {
            cachedRecommendations = RecommendationEngine.compute(
                from: historyStore.entries,
                allowlist: autoFixAllowlist,
                blocklist: autoFixBlocklist,
                customRules: customAutoReplaceRules,
                dismissed: dismissedRecommendations
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyWindowSectionRequest)) { note in
            if let section = note.userInfo?["section"] as? HistorySection {
                selection = section
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            brandTile
            Divider()
            List(selection: $selection) {
                row(.overview)
                row(.history)
                row(.suggestions, badge: cachedRecommendations.count)

                Section("Налаштування") {
                    row(.settingsGeneral)
                    row(.settingsLanguages)
                    row(.settingsRules)
                    row(.settingsShortcuts)
                    row(.settingsAccount)
                }
            }
            .listStyle(.sidebar)
            .tint(Color("BrandAccentDeep"))

            Divider()
            statusPill
        }
    }

    private var brandTile: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color("BrandAccent"), Color("BrandAccentDeep")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 30, height: 30)
                Image(systemName: "bird.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Papuga")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isServiceRunning ? Color("BrandAccent") : Color.secondary)
                .frame(width: 8, height: 8)
            Text(isServiceRunning ? "Слухаю" : "Вимкнено")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isServiceRunning ? .primary : .secondary)
            Spacer()
            Text(shortcutHint)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var shortcutHint: String {
        if useDoublePress {
            let preset = DoublePressShortcutPreset(rawValue: doublePressShortcut) ?? .optionShift
            return "\(preset.title) ×2"
        }
        return KeyboardShortcuts.getShortcut(for: .switchForward)?.description ?? "Своя комбінація"
    }

    @ViewBuilder
    private func row(_ section: HistorySection, badge: Int? = nil) -> some View {
        HStack {
            Label(section.title, systemImage: section.systemImage)
            Spacer()
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color("BrandAccent")))
            }
        }
        .tag(section)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .overview:
            AnalyticsTab(recommendations: cachedRecommendations)
        case .history:
            ReplacementsHistorySectionView()
        case .suggestions:
            RecommendationsSectionView(recommendations: cachedRecommendations)
        case .settingsGeneral:
            GeneralTab()
        case .settingsLanguages:
            LanguagesSettingsTab()
        case .settingsRules:
            AutoFixTab()
        case .settingsShortcuts:
            HotkeysTab()
        case .settingsAccount:
            AboutTab()
        }
    }

}
