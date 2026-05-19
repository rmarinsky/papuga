import Defaults
import SwiftUI

struct HistoryWindowView: View {
    @State private var selection: HistorySection
    @State private var historyStore = ReplacementHistoryStore.shared

    @Environment(LayoutManager.self) private var layoutManager
    @Environment(ClipboardHistoryManager.self) private var clipboardHistoryManager

    @Default(.autoFixAllowlist) private var autoFixAllowlist
    @Default(.autoFixBlocklist) private var autoFixBlocklist
    @Default(.customAutoReplaceRules) private var customAutoReplaceRules
    @Default(.dismissedRecommendations) private var dismissedRecommendations

    init(initialSection: HistorySection) {
        _selection = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detailView
        }
        .navigationTitle(selection.title)
        .onReceive(NotificationCenter.default.publisher(for: .historyWindowSectionRequest)) { note in
            if let section = note.userInfo?["section"] as? HistorySection {
                selection = section
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selection) {
            Section("Дані") {
                row(.clipboard)
                row(.replacements)
                row(.recommendations, badge: activeRecommendations.count)
            }

            Section("Налаштування") {
                row(.settingsGeneral)
                row(.settingsHotkeys)
                row(.settingsAutoFix)
                row(.settingsAnalytics)
                row(.settingsAbout)
            }
        }
        .listStyle(.sidebar)
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
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .tag(section)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .clipboard:
            ClipboardHistorySectionView()
        case .replacements:
            ReplacementsHistorySectionView()
        case .recommendations:
            RecommendationsSectionView(recommendations: activeRecommendations)
        case .settingsGeneral:
            GeneralTab()
        case .settingsHotkeys:
            HotkeysTab()
        case .settingsAutoFix:
            AutoFixTab()
        case .settingsAnalytics:
            AnalyticsTab()
        case .settingsAbout:
            AboutTab()
        }
    }

    private var activeRecommendations: [Recommendation] {
        RecommendationEngine.compute(
            from: historyStore.entries,
            allowlist: autoFixAllowlist,
            blocklist: autoFixBlocklist,
            customRules: customAutoReplaceRules,
            dismissed: dismissedRecommendations
        )
    }
}
