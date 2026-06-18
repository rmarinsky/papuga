import SwiftUI

struct UnifiedHistoryView: View {
    private enum HistoryMode: String, CaseIterable, Identifiable {
        case replacements
        case clipboard

        var id: String { rawValue }

        var title: String {
            switch self {
            case .replacements: return "Заміни"
            case .clipboard: return "Копіопасти"
            }
        }
    }

    @State private var mode: HistoryMode = .replacements

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Історія")
                    .font(.system(size: 20, weight: .bold))
                Text("Замінені слова і буфер обміну в одному місці.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $mode) {
                ForEach(HistoryMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var detail: some View {
        switch mode {
        case .replacements:
            ReplacementsHistorySectionView(compactChrome: true)
        case .clipboard:
            ClipboardHistorySectionView(compactChrome: true)
        }
    }
}
