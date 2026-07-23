import Defaults
import SwiftUI

struct TypingSpeedTestView: View {
    private struct Prompt: Identifiable, Equatable {
        let id: String
        let title: String
        let text: String
    }

    private static let prompts: [Prompt] = [
        Prompt(
            id: "uk-basic",
            title: "Українська",
            text: "Швидкий тест набору допомагає помітити, де губиться темп: пропуски, зайві літери та виправлення під час друку."
        ),
        Prompt(
            id: "autofix",
            title: "Автозаміна",
            text: "Автозаміна має допомагати тихо: не ламати терміни, не чіпати назви продуктів і показувати пропозицію тоді, коли є сумнів."
        ),
        Prompt(
            id: "mixed",
            title: "Змішаний",
            text: "When the layout is wrong, Papuga should suggest a fix without stealing focus or replacing text in the wrong editor."
        )
    ]

    @State private var selectedPromptID = Self.prompts[0].id
    @State private var typedText = ""
    @State private var startedAt: Date?
    @State private var finishedAt: Date?
    @State private var now = Date()
    @FocusState private var editorFocused: Bool

    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metricsRow
                    testCard
                    resultCard
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            editorFocused = true
        }
        .onReceive(timer) { date in
            guard startedAt != nil, finishedAt == nil else { return }
            now = date
        }
        .onChange(of: typedText) { _, newValue in
            handleTypedTextChange(newValue)
        }
        .onChange(of: selectedPromptID) { _, _ in
            reset()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Spacer()

            Picker("", selection: $selectedPromptID) {
                ForEach(Self.prompts) { prompt in
                    Text(prompt.title).tag(prompt.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button {
                pickNextPrompt()
            } label: {
                Label("Новий текст", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)

            Button {
                reset()
            } label: {
                Label("Скинути", systemImage: "restart")
            }
            .buttonStyle(.borderless)
            .disabled(typedText.isEmpty && startedAt == nil)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var metricsRow: some View {
        HStack(spacing: 10) {
            metric("WPM", value: "\(Int(metrics.wordsPerMinute.rounded()))", icon: "speedometer")
            metric("CPM", value: "\(Int(metrics.charactersPerMinute.rounded()))", icon: "keyboard")
            metric("Точність", value: "\(Int((metrics.accuracy * 100).rounded()))%", icon: "scope")
            metric("Помилки", value: "\(metrics.errorCharacters)", icon: "xmark.circle")
            metric("Час", value: formattedTime(metrics.elapsedSeconds), icon: "timer")
        }
    }

    private func metric(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color("BrandAccentDeep"))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
        )
    }

    private var testCard: some View {
        SectionCard(
            eyebrow: "ТЕКСТ",
            title: activePrompt.title,
            subtitle: "Набір стартує з першого символу. Виправлення враховуються в точності."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ProgressView(value: metrics.progress)
                    .tint(Color("BrandAccentDeep"))

                TypingPromptText(prompt: activePrompt.text, typedText: typedText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                    )

                TextEditor(text: $typedText)
                    .font(.system(size: 15, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 130)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.75))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(editorBorderColor, lineWidth: 1)
                            )
                    )
                    .focused($editorFocused)

                HStack {
                    Label(statusTitle, systemImage: statusIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(statusColor)
                    Spacer()
                    Text("\(metrics.typedCharacters)/\(activePrompt.text.count)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var resultCard: some View {
        if metrics.isComplete {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color("BrandAccentDeep"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Готово")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Результат: \(Int(metrics.wordsPerMinute.rounded())) WPM, \(Int((metrics.accuracy * 100).rounded()))% точності, \(metrics.errorCharacters) помилок.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Тепер економію часу рахуємо з твоєї швидкості друку.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    pickNextPrompt()
                } label: {
                    Label("Наступний текст", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("BrandAccentDeep"))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color("BrandTintSoft"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color("BrandTintBorder"), lineWidth: 1)
                    )
            )
        }
    }

    private var activePrompt: Prompt {
        Self.prompts.first { $0.id == selectedPromptID } ?? Self.prompts[0]
    }

    private var metrics: TypingSpeedMetrics {
        TypingSpeedTestEngine.metrics(
            prompt: activePrompt.text,
            typedText: typedText,
            elapsedSeconds: elapsedSeconds
        )
    }

    private var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    private var editorBorderColor: Color {
        if metrics.isComplete { return Color("BrandAccentDeep").opacity(0.6) }
        if metrics.errorCharacters > 0 { return .red.opacity(0.38) }
        return Color.primary.opacity(0.1)
    }

    private var statusTitle: String {
        if metrics.isComplete { return "Тест завершено" }
        if startedAt == nil { return "Готово до набору" }
        if metrics.errorCharacters > 0 { return "Є помилки у введеному тексті" }
        return "Набір триває"
    }

    private var statusIcon: String {
        if metrics.isComplete { return "checkmark.circle.fill" }
        if startedAt == nil { return "keyboard" }
        if metrics.errorCharacters > 0 { return "exclamationmark.triangle.fill" }
        return "record.circle"
    }

    private var statusColor: Color {
        if metrics.isComplete { return Color("BrandAccentDeep") }
        if metrics.errorCharacters > 0 { return .red }
        return .secondary
    }

    private func handleTypedTextChange(_ value: String) {
        if startedAt == nil, !value.isEmpty {
            startedAt = Date()
            now = startedAt ?? now
        }

        if value == activePrompt.text, finishedAt == nil {
            finishedAt = Date()
            now = finishedAt ?? now
            persistMeasuredSpeed()
        } else if value != activePrompt.text {
            finishedAt = nil
        }
    }

    /// Persists the completed test's net WPM so the time-saved estimate is
    /// computed from the user's real speed instead of the 40 WPM default.
    private func persistMeasuredSpeed() {
        let result = metrics
        guard result.isComplete,
              result.wordsPerMinute.isFinite,
              result.wordsPerMinute >= 5 else { return }
        Defaults[.measuredTypingWPM] = Constants.sanitizedTypingWordsPerMinute(result.wordsPerMinute)
    }

    private func reset() {
        typedText = ""
        startedAt = nil
        finishedAt = nil
        now = Date()
        editorFocused = true
    }

    private func pickNextPrompt() {
        guard let index = Self.prompts.firstIndex(where: { $0.id == selectedPromptID }) else {
            selectedPromptID = Self.prompts[0].id
            reset()
            return
        }
        selectedPromptID = Self.prompts[(index + 1) % Self.prompts.count].id
        reset()
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

private struct TypingPromptText: View {
    let prompt: String
    let typedText: String

    var body: some View {
        // Hoist Array(typedText) out of the per-character closure so it is created O(1)
        // per body evaluation instead of O(n) times (once per character via foregroundColor).
        let typed = Array(typedText)
        FlowLayout(spacing: 0, lineSpacing: 4) {
            ForEach(Array(prompt.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(foregroundColor(at: index, expected: character, typed: typed))
                    .padding(.horizontal, index == typedText.count ? 1 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(index == typedText.count ? Color("BrandAccentDeep").opacity(0.16) : .clear)
                    )
            }
        }
    }

    private func foregroundColor(at index: Int, expected: Character, typed: [Character]) -> Color {
        guard index < typed.count else { return .secondary }
        return typed[index] == expected ? Color("BrandAccentDeep") : .red
    }
}
