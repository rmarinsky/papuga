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

    private let minWordLengthOptions = [2, 3, 4, 5]

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
                Text("Якщо клікнути по папузі — заміна скасується, а слово запам'ятається у списку «не чіпати»")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Визначення мови") {
                Picker("Мінімальна довжина слова", selection: $autoFixMinWordLength) {
                    ForEach(minWordLengthOptions, id: \.self) { n in
                        Text("\(n) симв.").tag(n)
                    }
                }
                .pickerStyle(.menu)
                Text("Коротші слова автозаміна ігнорує, щоб не чіпати випадкові фрагменти.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Алгоритм визначення мови", selection: $autoFixAlgorithm) {
                    ForEach(LanguageScorerAlgorithm.implementedCases, id: \.rawValue) { algorithm in
                        Text(algorithm.title).tag(algorithm.rawValue)
                    }
                }
                .pickerStyle(.menu)

                if let selected = LanguageScorerAlgorithm(rawValue: autoFixAlgorithm) {
                    Text(selected.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("Поріг впевненості")
                        Spacer()
                        Text(String(format: "%.2f", autoFixThreshold)).monospacedDigit()
                    }
                    Slider(value: $autoFixThreshold, in: 0.1...0.9, step: 0.05)
                }
            }

            Section("Слова та правила") {
                Label(
                    "Списки «не чіпати» та власні правила заміни переїхали у вкладку «Словник».",
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
