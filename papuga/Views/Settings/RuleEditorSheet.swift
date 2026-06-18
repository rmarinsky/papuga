import Defaults
import SwiftUI

/// What to seed the editor with. `ruleID == nil` means "creating", otherwise we
/// edit (or convert) the existing custom rule with that id.
struct RuleEditorSeed: Identifiable {
    let id = UUID()
    var ruleID: UUID?
    var allowlistOriginal: String?
    var source: String = ""
    var target: String = ""
    var mode: RuleEditorSheet.Mode = .replace

    init(
        ruleID: UUID? = nil,
        allowlistOriginal: String? = nil,
        source: String = "",
        target: String = "",
        mode: RuleEditorSheet.Mode = .replace
    ) {
        self.ruleID = ruleID
        self.allowlistOriginal = allowlistOriginal
        self.source = source
        self.target = target
        self.mode = mode
    }
}

struct RuleEditorSaveResult {
    let mode: RuleEditorSheet.Mode
    let source: String
    let target: String?
}

/// The "edit replacement" modal. One sheet handles both intents the user can
/// express about a word: **replace it** with something (a custom rule) or
/// **leave it alone** (the allowlist). The two are mutually exclusive, so saving
/// one clears the other for the same word.
struct RuleEditorSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case replace
        case leaveAlone
        var id: String { rawValue }
        var title: String {
            switch self {
            case .replace: return "Заміняти"
            case .leaveAlone: return "Не чіпати"
            }
        }
    }

    private enum Field { case source, target }

    let seed: RuleEditorSeed
    var onClose: () -> Void
    var onSave: ((RuleEditorSaveResult) -> Void)?

    @State private var mode: Mode
    @State private var source: String
    @State private var target: String
    @FocusState private var focus: Field?

    @Default(.autoFixAllowlist) private var allowlist
    @Default(.customAutoReplaceRules) private var customRules

    init(
        seed: RuleEditorSeed,
        onClose: @escaping () -> Void,
        onSave: ((RuleEditorSaveResult) -> Void)? = nil
    ) {
        self.seed = seed
        self.onClose = onClose
        self.onSave = onSave
        _mode = State(initialValue: seed.mode)
        _source = State(initialValue: seed.source)
        _target = State(initialValue: seed.target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            focus = source.isEmpty ? .source : (mode == .replace ? .target : .source)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color("BrandAccent"), Color("BrandAccentDeep")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(seed.ruleID == nil ? "Нове правило" : "Редагувати правило")
                    .font(.system(size: 15, weight: .semibold))
                Text(mode == .replace ? "Власна заміна для автозаміни" : "Слово, яке Papuga має лишати як є")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            field(
                eyebrow: "ТИ ДРУКУЄШ",
                text: $source,
                placeholder: "напр. ghbdtn",
                mono: true,
                tint: .primary,
                field: .source
            )

            if mode == .replace {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                    .frame(maxWidth: .infinity, alignment: .center)

                field(
                    eyebrow: "PAPUGA ДРУКУЄ",
                    text: $target,
                    placeholder: "напр. привіт",
                    mono: false,
                    tint: Color("BrandAccentDeep"),
                    field: .target
                )
            } else {
                Label("Papuga залишить це слово як є — навіть якщо воно схоже на іншу мову.",
                      systemImage: "hand.raised")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            preview

            if let conflictText {
                Label(conflictText, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var preview: some View {
        if sourceValid {
            VStack(alignment: .leading, spacing: 6) {
                Text("ПРЕВ'Ю")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                if mode == .replace, !trimmedTarget.isEmpty {
                    ReplacementReceipt(source: trimmedSource, target: trimmedTarget, strikethroughSource: true)
                } else if mode == .leaveAlone {
                    HStack(spacing: 7) {
                        SourcePill(text: trimmedSource)
                        Image(systemName: "hand.raised")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color("BrandAccentDeep"))
                        Text("не чіпати")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color("BrandTintSoft").opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color("BrandTintBorder"), lineWidth: 1)
                    )
            )
        }
    }

    private func field(
        eyebrow: String,
        text: Binding<String>,
        placeholder: String,
        mono: Bool,
        tint: Color,
        field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(mono ? .system(size: 15, design: .monospaced) : .system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .focused($focus, equals: field)
                .onSubmit { if canSave { save() } }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    focus == field ? Color("BrandAccentDeep").opacity(0.7) : Color.primary.opacity(0.1),
                                    lineWidth: focus == field ? 2 : 1
                                )
                        )
                )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Скасувати") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button(seed.ruleID == nil ? "Створити" : "Зберегти") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandAccentDeep"))
                .disabled(!canSave)
        }
        .padding(16)
    }

    // MARK: - Validation + save

    private var trimmedSource: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var sourceValid: Bool {
        trimmedSource.count >= 1 && !trimmedSource.contains(where: \.isWhitespace)
    }

    private var canSave: Bool {
        guard sourceValid else { return false }
        switch mode {
        case .leaveAlone:
            return true
        case .replace:
            return !trimmedTarget.isEmpty
                && !trimmedTarget.contains(where: \.isWhitespace)
                && trimmedTarget.lowercased() != trimmedSource.lowercased()
        }
    }

    private var conflictText: String? {
        guard sourceValid else { return nil }
        let sourceWasAllowlisted = seed.allowlistOriginal?.caseInsensitiveCompare(trimmedSource) == .orderedSame
        let sourceHasAllowlist = allowlist.contains {
            $0.caseInsensitiveCompare(trimmedSource) == .orderedSame
        }
        let sourceHasOtherRule = customRules.contains {
            $0.id != seed.ruleID && $0.source.caseInsensitiveCompare(trimmedSource) == .orderedSame
        }

        switch mode {
        case .replace where sourceHasAllowlist:
            return "Після збереження слово буде прибране зі списку «не чіпати»."
        case .replace where sourceHasOtherRule:
            return "Існуюче правило для цього слова буде замінене."
        case .leaveAlone where sourceHasOtherRule:
            return "Після збереження кастомне правило для цього слова буде видалене."
        case .leaveAlone where sourceHasAllowlist && !sourceWasAllowlisted:
            return "Це слово вже є у списку «не чіпати»."
        default:
            return nil
        }
    }

    private func save() {
        guard canSave else { return }
        let src = trimmedSource

        switch mode {
        case .replace:
            // A word can't be both replaced and left alone.
            allowlist.removeAll { $0.caseInsensitiveCompare(src) == .orderedSame }
            if let original = seed.allowlistOriginal {
                allowlist.removeAll { $0.caseInsensitiveCompare(original) == .orderedSame }
            }
            if let ruleID = seed.ruleID, let idx = customRules.firstIndex(where: { $0.id == ruleID }) {
                customRules[idx].source = src
                customRules[idx].target = trimmedTarget
            } else {
                // Only the first matching rule fires at runtime, so a duplicate
                // source would be dead weight — replace any existing one.
                customRules.removeAll { $0.source.caseInsensitiveCompare(src) == .orderedSame }
                customRules.append(CustomAutoReplaceRule(source: src, target: trimmedTarget))
            }

        case .leaveAlone:
            customRules.removeAll { $0.source.caseInsensitiveCompare(src) == .orderedSame }
            if let ruleID = seed.ruleID {
                customRules.removeAll { $0.id == ruleID }
            }
            if let original = seed.allowlistOriginal {
                allowlist.removeAll { $0.caseInsensitiveCompare(original) == .orderedSame }
            }
            IgnoreWordService.add(src)
        }

        onSave?(RuleEditorSaveResult(
            mode: mode,
            source: src,
            target: mode == .replace ? trimmedTarget : nil
        ))
        onClose()
    }
}
