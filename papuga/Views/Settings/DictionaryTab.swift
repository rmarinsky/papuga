import Defaults
import SwiftUI

/// "Словник" — the words Papuga must know about. Two lists pulled out of the
/// crammed Rules tab: words to **leave alone** (a hover-to-remove tag cloud) and
/// custom **replace** rules (editable source → target receipts).
struct DictionaryTab: View {
    @Default(.autoFixAllowlist) private var allowlist
    @Default(.customAutoReplaceRules) private var customRules

    @State private var editorSeed: RuleEditorSeed?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                dontReplaceCard
                alwaysReplaceCard
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $editorSeed) { seed in
            RuleEditorSheet(seed: seed) { editorSeed = nil }
        }
    }

    // MARK: - Don't replace (tag cloud)

    private var dontReplaceCard: some View {
        SectionCard(
            eyebrow: "НЕ ЧІПАТИ",
            title: "Слова, які Papuga залишає як є",
            subtitle: "Акроніми, ніки, команди — щоб автозаміна їх не торкалась."
        ) {
            if allowlist.isEmpty {
                emptyHint("Список порожній. Клікни папугу під час її анімації або додай слово вручну.")
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(allowlist, id: \.self) { word in
                    AllowlistChip(word: word) {
                        allowlist.removeAll { $0 == word }
                    }
                }
                AddWordChip(existing: allowlist) { word in
                    allowlist.append(word)
                }
            }
        }
    }

    // MARK: - Always replace (rules)

    private var alwaysReplaceCard: some View {
        SectionCard(
            eyebrow: "ЗАМІНЯТИ ЗАВЖДИ",
            title: "Власні правила заміни",
            subtitle: "Papuga підмінятиме ліве слово на праве — будь-де, поки ти друкуєш."
        ) {
            if customRules.isEmpty {
                emptyHint("Ще немає правил. Створи перше або прийми пораду у вкладці «Поради».")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(customRules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 {
                            Divider().opacity(0.4)
                        }
                        RuleRow(
                            rule: rule,
                            onEdit: {
                                editorSeed = RuleEditorSeed(
                                    ruleID: rule.id,
                                    source: rule.source,
                                    target: rule.target,
                                    mode: .replace
                                )
                            },
                            onDelete: { customRules.removeAll { $0.id == rule.id } }
                        )
                    }
                }
            }

            Button {
                editorSeed = RuleEditorSeed(mode: .replace)
            } label: {
                Label("Нове правило", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color("BrandAccentDeep"))
            .padding(.top, 2)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tag-cloud chip with hover-reveal remove

private struct AllowlistChip: View {
    let word: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(word)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Прибрати «\(word)»")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, hovering ? 6 : 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.quaternary)
                .overlay(
                    Capsule().stroke(Color("BrandAccentDeep").opacity(hovering ? 0.4 : 0), lineWidth: 1)
                )
        )
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Dashed "add word" chip with inline popover

private struct AddWordChip: View {
    let existing: [String]
    let onAdd: (String) -> Void

    @State private var showingPopover = false
    @State private var text = ""

    var body: some View {
        Button { showingPopover = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("Додати").font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().strokeBorder(
                    .tertiary,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                TextField("Слово", text: $text)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                    .onSubmit(commit)
                Button("Додати", action: commit)
                    .disabled(!isValid)
            }
            .padding(12)
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isValid: Bool {
        !trimmed.isEmpty
            && !trimmed.contains(where: \.isWhitespace)
            && !existing.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func commit() {
        guard isValid else { return }
        onAdd(trimmed)
        text = ""
        showingPopover = false
    }
}

// MARK: - Editable rule row (hover-reveal edit / delete)

private struct RuleRow: View {
    let rule: CustomAutoReplaceRule
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ReplacementReceipt(source: rule.source, target: rule.target)

            if rule.createdFromRecommendation {
                Text("із поради")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }

            Spacer(minLength: 8)

            if hovering {
                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Редагувати")

                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Видалити правило")
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}
