import SwiftUI
import Defaults

struct AutoFixTab: View {
    @Default(.autoFixEnabled) private var autoFixEnabled
    @Default(.autoFixUndoWindow) private var autoFixUndoWindow
    @Default(.autoFixBlocklist) private var autoFixBlocklist
    @Default(.autoFixAllowlist) private var autoFixAllowlist
    @Default(.autoFixToastEnabled) private var autoFixToastEnabled
    @Default(.customAutoReplaceRules) private var customAutoReplaceRules

    @State private var showingAddSheet = false
    @State private var newAllowlistWord = ""
    @State private var newRuleSource = ""
    @State private var newRuleTarget = ""

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
                Text("Якщо клікнути по папузі — заміна скасується, а слово запам'ятається у списку «не чіпати»")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Не чіпати ці слова") {
                if autoFixAllowlist.isEmpty {
                    Text("Список порожній. Слова додаються автоматично, коли ти клікаєш папугу під час її анімації, або вручну тут.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(autoFixAllowlist, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            autoFixAllowlist.removeAll { $0 == word }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Додати слово вручну", text: $newAllowlistWord)
                    Button("Додати") {
                        let trimmed = newAllowlistWord.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && !autoFixAllowlist.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
                            autoFixAllowlist.append(trimmed)
                            newAllowlistWord = ""
                        }
                    }
                    .disabled(newAllowlistWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Власні правила автозаміни") {
                if customAutoReplaceRules.isEmpty {
                    Text("Тут з'являться твої правила, коли ти приймеш рекомендацію, або додаси їх вручну.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(customAutoReplaceRules) { rule in
                    HStack {
                        Text(rule.source).font(.system(.body, design: .monospaced))
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text(rule.target).font(.system(.body, design: .monospaced))
                        Spacer()
                        if rule.createdFromRecommendation {
                            Text("із поради")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            customAutoReplaceRules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Замінити", text: $newRuleSource)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("На", text: $newRuleTarget)
                    Button("Додати") {
                        let src = newRuleSource.trimmingCharacters(in: .whitespacesAndNewlines)
                        let tgt = newRuleTarget.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !src.isEmpty, !tgt.isEmpty else { return }
                        // Reject any rule whose source already exists — at runtime only the
                        // first match fires, so a duplicate-source rule would be dead weight.
                        guard !customAutoReplaceRules.contains(where: {
                            $0.source.lowercased() == src.lowercased()
                        }) else { return }
                        customAutoReplaceRules.append(
                            CustomAutoReplaceRule(source: src, target: tgt)
                        )
                        newRuleSource = ""
                        newRuleTarget = ""
                    }
                    .disabled(
                        newRuleSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        newRuleTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
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
    }

    private func displayName(for bundleID: String) -> String {
        AppContextProvider.runningAppCandidates()
            .first { $0.bundleID == bundleID }?
            .name ?? bundleID
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
