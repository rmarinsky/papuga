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

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            brandTile
            Divider()
            List(selection: $selection) {
                row(.overview)
                row(.history)
                row(.suggestions, badge: activeRecommendations.count)

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
            Text("PRO")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color("ProBadgeText"))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color("ProBadgeBg")))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            AnalyticsTab()
        case .history:
            HistoryDetailView()
        case .suggestions:
            RecommendationsSectionView(recommendations: activeRecommendations)
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

// MARK: - History internal switcher

private struct HistoryDetailView: View {
    enum HistoryKind: String, CaseIterable, Identifiable {
        case replacements, clipboard
        var id: String { rawValue }
        var title: String {
            switch self {
            case .replacements: return "Заміни"
            case .clipboard: return "Копіопасти"
            }
        }
    }

    @State private var kind: HistoryKind = .replacements

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $kind) {
                    ForEach(HistoryKind.allCases) { k in
                        Text(k.title).tag(k)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                Spacer()
            }
            .padding(12)

            Divider()

            switch kind {
            case .replacements:
                ReplacementsHistorySectionView()
            case .clipboard:
                ClipboardHistorySectionView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
