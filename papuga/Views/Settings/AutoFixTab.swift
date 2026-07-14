import SwiftUI
import Defaults

struct AutoFixTab: View {
    @Default(.autoFixEnabled) private var autoFixEnabled
    @Default(.autoFixUndoWindow) private var autoFixUndoWindow
    @Default(.autoFixBlocklist) private var autoFixBlocklist
    @Default(.autoFixToastEnabled) private var autoFixToastEnabled
    @Default(.autoFixAlgorithm) private var autoFixAlgorithm
    @Default(.autoFixThreshold) private var autoFixThreshold
    @Default(.autoFixMinWordLength) private var autoFixMinWordLength
    @Default(.autoFixConservativeEditingGuard) private var autoFixConservativeEditingGuard
    @Default(.autoFixSpellingTypoGuardEnabled) private var autoFixSpellingTypoGuardEnabled
    @Default(.autoFixSpellingTypoGuardMinWordLength) private var autoFixSpellingTypoGuardMinWordLength
    @Default(.autoFixSpellingTypoGuardMaxEditDistance) private var autoFixSpellingTypoGuardMaxEditDistance
    @Default(.autoFixProposalEnabled) private var autoFixProposalEnabled
    @Default(.autoFixProposalWindow) private var autoFixProposalWindow
    @Default(.autoFixLayoutSwitchPolicy) private var autoFixLayoutSwitchPolicy

    @State private var showingAddSheet = false

    var body: some View {
        Form {
            Section("Автозаміна під час набору") {
                Toggle("Увімкнути автозаміну", isOn: $autoFixEnabled)

                VStack(alignment: .leading) {
                    HStack {
                        Text("Вікно для скасування (Backspace)")
                        Spacer()
                        Text(String(format: "%.1f сек", autoFixUndoWindow)).monospacedDigit()
                    }
                    Slider(value: $autoFixUndoWindow, in: 0.5...3.0, step: 0.1)
                }

                Toggle("Показувати папугу-сальто біля курсора", isOn: $autoFixToastEnabled)
                Text("Якщо клікнути по папузі — заміна скасується, а слово запам'ятається у списку «не чіпати» і словнику macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Не автозаміняти фрагменти після редагування слова", isOn: $autoFixConservativeEditingGuard)
                Text("Після Backspace або руху курсора Papuga пропустить наступний фрагмент, щоб не видаляти частину слова.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Показувати компактні пропозиції", isOn: $autoFixProposalEnabled)
                Text("Якщо заміна майже дотягує до порогу, Papuga запропонує її поруч із курсором замість тихої автозаміни.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Визначення мови") {
                Picker("Режим", selection: sensitivityPreset) {
                    ForEach(AutoFixSensitivityPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(currentSensitivityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Показувати пропозиції біля курсора", isOn: $autoFixProposalEnabled)
                Text("Сумнівні слова та фрази Papuga покаже як підказку: Enter замінює, Esc ігнорує надалі.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Не чіпати правописні опечатки", isOn: $autoFixSpellingTypoGuardEnabled)
                Text("Опечатки в поточній мові лишаються як є, замість перетворення в іншу розкладку.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Двомовний текст") {
                Picker("Після заміни", selection: $autoFixLayoutSwitchPolicy) {
                    ForEach(AutoFixLayoutSwitchPolicy.allCases, id: \.rawValue) { policy in
                        Text(policy.title).tag(policy.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Text("Адаптивний режим не перемикає розкладку після одиночного терміна, але перемикає після фрази або повторних замін в одному напрямку.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label(
                    "Акроніми та технічні терміни на кшталт API, QA, macOS, SwiftUI, git не автозамінюються.",
                    systemImage: "textformat.abc"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Редактори коду") {
                Label(
                    "У VS Code, Cursor, JetBrains, Xcode Papuga за замовчуванням показує пропозицію замість прямої автозаміни, щоб не ламати multi-cursor.",
                    systemImage: "curlybraces"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Слова та правила") {
                Label(
                    "Списки «не чіпати» та власні правила заміни доступні у сегменті «Словник».",
                    systemImage: "character.book.closed"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Не застосовувати у цих застосунках") {
                if autoFixBlocklist.isEmpty {
                    Text("Список порожній — автозаміна працює всюди.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(autoFixBlocklist, id: \.self) { bundleID in
                    HStack {
                        Text(displayName(for: bundleID))
                        Spacer()
                        Text(bundleID).font(.caption).foregroundStyle(.secondary)
                        Button {
                            autoFixBlocklist.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Додати застосунок", systemImage: "plus.circle")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddSheet) {
            AutoFixBlocklistAddSheet(
                blocklist: $autoFixBlocklist,
                isPresented: $showingAddSheet
            )
        }
        .onAppear {
            if let selected = LanguageScorerAlgorithm(rawValue: autoFixAlgorithm), selected.isImplemented {
                return
            }
            autoFixAlgorithm = LanguageScorerAlgorithm.appleNL.rawValue
        }
    }

    private func displayName(for bundleID: String) -> String {
        AppContextProvider.runningAppCandidates()
            .first { $0.bundleID == bundleID }?
            .name ?? bundleID
    }

    private var sensitivityPreset: Binding<AutoFixSensitivityPreset> {
        Binding(
            get: {
                AutoFixSensitivityPreset.nearest(
                    minWordLength: autoFixMinWordLength,
                    threshold: autoFixThreshold,
                    proposalWindow: autoFixProposalWindow
                )
            },
            set: { preset in
                applySensitivityPreset(preset)
            }
        )
    }

    private var currentSensitivityDescription: String {
        sensitivityPreset.wrappedValue.description
    }

    private func applySensitivityPreset(_ preset: AutoFixSensitivityPreset) {
        autoFixMinWordLength = preset.minWordLength
        autoFixThreshold = preset.threshold
        autoFixProposalWindow = preset.proposalWindow
        autoFixSpellingTypoGuardMinWordLength = preset.typoGuardMinWordLength
        autoFixSpellingTypoGuardMaxEditDistance = preset.typoGuardMaxEditDistance
        autoFixAlgorithm = LanguageScorerAlgorithm.appleNL.rawValue
    }
}

private enum AutoFixSensitivityPreset: String, CaseIterable, Identifiable {
    case careful
    case balanced
    case moreHints

    var id: String { rawValue }

    var title: String {
        switch self {
        case .careful: return "Обмежено"
        case .balanced: return "Збалансовано"
        case .moreHints: return "Більше підказок"
        }
    }

    var description: String {
        switch self {
        case .careful:
            return "Лише дуже впевнені випадки. Сумнівні слова Papuga переважно ігнорує, а підказки показує рідко."
        case .balanced:
            return "Впевнені помилки Papuga замінює автоматично, сумнівні показує як підказку, а слабкі сигнали ігнорує."
        case .moreHints:
            return "Papuga частіше пропонує варіант для сумнівних і коротких слів, але автоматично замінює лише впевнені випадки."
        }
    }

    var minWordLength: Int {
        switch self {
        case .careful: return 4
        case .balanced: return 3
        case .moreHints: return 2
        }
    }

    var threshold: Double {
        switch self {
        case .careful: return 0.45
        case .balanced: return 0.35
        case .moreHints: return 0.50
        }
    }

    var proposalWindow: Double {
        switch self {
        case .careful: return 0.14
        case .balanced: return 0.22
        case .moreHints: return 0.35
        }
    }

    var typoGuardMinWordLength: Int {
        switch self {
        case .careful: return 3
        case .balanced, .moreHints: return 4
        }
    }

    var typoGuardMaxEditDistance: Int {
        1
    }

    static func nearest(
        minWordLength: Int,
        threshold: Double,
        proposalWindow: Double
    ) -> AutoFixSensitivityPreset {
        allCases.min { lhs, rhs in
            lhs.distance(toMinWordLength: minWordLength, threshold: threshold, proposalWindow: proposalWindow)
                < rhs.distance(toMinWordLength: minWordLength, threshold: threshold, proposalWindow: proposalWindow)
        } ?? .balanced
    }

    private func distance(
        toMinWordLength minWordLength: Int,
        threshold: Double,
        proposalWindow: Double
    ) -> Double {
        abs(Double(self.minWordLength - minWordLength)) * 0.2
            + abs(self.threshold - threshold)
            + abs(self.proposalWindow - proposalWindow)
    }
}

private struct AutoFixBlocklistAddSheet: View {
    @Binding var blocklist: [String]
    @Binding var isPresented: Bool
    @State private var manualBundleID = ""
    @State private var candidates: [(bundleID: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Виберіть застосунок або введіть Bundle ID").font(.headline)

            List {
                ForEach(candidates, id: \.bundleID) { candidate in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(candidate.name)
                            Text(candidate.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if blocklist.contains(candidate.bundleID) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Додати") {
                                if !blocklist.contains(candidate.bundleID) {
                                    blocklist.append(candidate.bundleID)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 240)

            Divider()

            HStack {
                TextField("com.example.MyApp", text: $manualBundleID)
                Button("Додати вручну") {
                    let trimmed = manualBundleID.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && !blocklist.contains(trimmed) {
                        blocklist.append(trimmed)
                        manualBundleID = ""
                    }
                }
                .disabled(manualBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Spacer()
                Button("Готово") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460, height: 420)
        .onAppear {
            candidates = AppContextProvider.runningAppCandidates()
        }
    }
}
