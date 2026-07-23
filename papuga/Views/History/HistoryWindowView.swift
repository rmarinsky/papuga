import Defaults
import KeyboardShortcuts
import SwiftUI

struct HistoryWindowView: View {
    @State private var selection: HistorySection
    @State private var hoveredSection: HistorySection?
    @State private var historyStore = ReplacementHistoryStore.shared
    @State private var mistakeStore = MistakeObservationStore.shared
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
        "\(historyStore.entries.count)|\(mistakeStore.entries.count)|\(autoFixAllowlist.joined())|\(autoFixBlocklist.joined())|\(customAutoReplaceRules.count)|\(dismissedRecommendations.joined())"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea(.container, edges: .top)
        }
        .task(id: recommendationCacheKey) {
            cachedRecommendations = RecommendationEngine.compute(
                from: historyStore.entries,
                mistakes: mistakeStore.entries,
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
            Color.clear.frame(height: 50)
            brandTile
                .padding(.horizontal, 16)

            Color.clear.frame(height: 18)
            sidebarRow(.overview)
            sidebarRow(.history)
            sidebarRow(.mistakes, badge: openMistakeCount)
            sidebarRow(.dictionary)
            sidebarRow(.clipboard)

            Color.clear.frame(height: 34)
            sidebarSectionHeader("НАЛАШТУВАННЯ")
            Color.clear.frame(height: 8)
            sidebarRow(.settingsGeneral)
            sidebarRow(.settingsLanguages)
            sidebarRow(.settingsRules)
            sidebarRow(.settingsShortcuts)
            sidebarRow(.settingsAI)
            sidebarRow(.settingsAccount)

            Color.clear.frame(height: 18)
            sidebarSectionHeader("ІНСТРУМЕНТИ")
            Color.clear.frame(height: 8)
            sidebarRow(.typingTest)

            Spacer(minLength: 16)
            statusPill
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var brandTile: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("🦜")
                .font(.system(size: 25))
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Papuga")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("PRO")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color("ProBadgeText"))
                    .padding(.horizontal, 7)
                    .frame(height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color("ProBadgeBg"))
                    )
            }
            Spacer()
        }
        .frame(height: 36, alignment: .top)
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
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var shortcutHint: String {
        if useDoublePress {
            let preset = DoublePressShortcutPreset(rawValue: doublePressShortcut) ?? .optionShift
            return "\(preset.title) ×2"
        }
        return KeyboardShortcuts.getShortcut(for: .switchForward)?.description ?? "Своя комбінація"
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.7)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 12)
            .padding(.horizontal, 20)
    }

    private func sidebarRow(_ section: HistorySection, badge: Int? = nil) -> some View {
        let isSelected = selection == section
        let isHovered = hoveredSection == section

        return Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 14, height: 14)

                Text(section.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? Color("BrandAccentDeep") : .white)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.9) : Color("BrandAccent"))
                        )
                }
            }
            .foregroundStyle(isSelected ? .white : .secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground(isSelected: isSelected, isHovered: isHovered))
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .onHover { isHovering in
            hoveredSection = isHovering ? section : nil
        }
        .accessibilityLabel(section.title)
    }

    private func rowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return Color("BrandAccentDeep")
        }
        if isHovered {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .overview:
            AnalyticsTab(recommendations: cachedRecommendations)
        case .typingTest:
            TypingSpeedTestView()
        case .history:
            ReplacementsHistorySectionView()
        case .clipboard:
            ClipboardHistorySectionView()
        case .mistakes:
            MistakesView()
        case .dictionary:
            settingsDetail {
                DictionaryTab()
            }
        case .settingsGeneral:
            settingsDetail {
                GeneralTab()
            }
        case .settingsLanguages:
            settingsDetail {
                LanguagesSettingsTab()
            }
        case .settingsRules:
            settingsDetail {
                RulesSettingsView()
            }
        case .settingsShortcuts:
            settingsDetail {
                HotkeysTab()
            }
        case .settingsAI:
            settingsDetail {
                AISettingsTab()
            }
        case .settingsAccount:
            settingsDetail {
                AboutTab()
            }
        }
    }

    private func settingsDetail<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
                .contentMargins(.top, 8, for: .scrollContent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var openMistakeCount: Int {
        mistakeStore.entries.filter { $0.status == .open }.count
    }
}
