import SwiftUI

struct ActionableHistoryScreen<Content: View>: View {
    let searchPlaceholder: String
    @Binding var range: HistoryTimeRange
    @Binding var query: String
    let clearDisabled: Bool
    let clearConfirmationTitle: String
    let onClear: () -> Void
    let content: () -> Content

    @State private var showingClearConfirmation = false

    init(
        searchPlaceholder: String = "Пошук",
        range: Binding<HistoryTimeRange>,
        query: Binding<String>,
        clearDisabled: Bool,
        clearConfirmationTitle: String,
        onClear: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.searchPlaceholder = searchPlaceholder
        _range = range
        _query = query
        self.clearDisabled = clearDisabled
        self.clearConfirmationTitle = clearConfirmationTitle
        self.onClear = onClear
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content()
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Spacer(minLength: 0)

            Picker("", selection: $range) {
                ForEach(HistoryTimeRange.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            searchField

            Button(role: .destructive) {
                showingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Очистити \(range.clearScopeTitle)")
            .accessibilityLabel("Очистити")
            .disabled(clearDisabled)
            .confirmationDialog(
                clearConfirmationTitle,
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Очистити", role: .destructive, action: onClear)
                Button("Скасувати", role: .cancel) {}
            } message: {
                Text("Цю дію не можна скасувати.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .frame(width: 140)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

struct HistoryRowActions: View {
    let canAct: Bool
    let disabledReason: String?
    let ruleDisabledReason: String?
    let onCreateRule: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onIgnore) {
                Label("Зберегти в словник", systemImage: "character.book.closed")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canAct)
            .help(disabledReason ?? "Зберегти слово у словник (Papuga не чіпатиме його)")

            Button(action: onCreateRule) {
                Label("Створити правило заміни", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Color("BrandAccentDeep"))
            .disabled(!canAct || ruleDisabledReason != nil)
            .help(ruleDisabledReason ?? disabledReason ?? "Відкрити модалку створення правила заміни")
        }
    }
}

enum HistoryWordActionPolicy {
    static func normalizedSource(_ text: String) -> String {
        BufferedToken.normalizedCore(from: text)
    }

    static func canUseSource(_ text: String, truncated: Bool) -> Bool {
        disabledReason(source: text, truncated: truncated) == nil
    }

    static func disabledReason(source: String, truncated: Bool) -> String? {
        let source = normalizedSource(source)
        if truncated {
            return "Обрізаний запис не можна безпечно перетворити на правило."
        }
        if source.count < 2 {
            return "Потрібне слово з двох або більше символів."
        }
        if source.contains(where: \.isWhitespace) {
            return "Правила і «не чіпати» зараз працюють тільки з одним словом."
        }
        return nil
    }

    static func sanitizedTarget(_ text: String?, truncated: Bool = false) -> String? {
        guard !truncated, let text else { return nil }
        let target = BufferedToken.normalizedCore(from: text)
        guard !target.isEmpty, !target.contains(where: \.isWhitespace) else { return nil }
        return target
    }

}
