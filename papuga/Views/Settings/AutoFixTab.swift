import SwiftUI
import Defaults

struct AutoFixTab: View {
    @Default(.autoFixEnabled) private var autoFixEnabled
    @Default(.autoFixAlgorithm) private var autoFixAlgorithm
    @Default(.autoFixThreshold) private var autoFixThreshold
    @Default(.autoFixUndoWindow) private var autoFixUndoWindow
    @Default(.autoFixBlocklist) private var autoFixBlocklist

    @State private var showingAddSheet = false

    var body: some View {
        Form {
            Section("Автозаміна під час набору") {
                Toggle("Увімкнути автозаміну", isOn: $autoFixEnabled)

                Picker("Алгоритм визначення мови", selection: $autoFixAlgorithm) {
                    ForEach(LanguageScorerAlgorithm.allCases, id: \.rawValue) { algorithm in
                        Text(algorithm.title).tag(algorithm.rawValue)
                    }
                }
                .pickerStyle(.menu)

                if let selected = LanguageScorerAlgorithm(rawValue: autoFixAlgorithm) {
                    Text(selected.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !selected.isImplemented {
                        Text("Поки використовує Apple NL замість цієї опції.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("Поріг впевненості")
                        Spacer()
                        Text(String(format: "%.2f", autoFixThreshold)).monospacedDigit()
                    }
                    Slider(value: $autoFixThreshold, in: 0.1...0.9, step: 0.05)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("Вікно для скасування (Backspace)")
                        Spacer()
                        Text(String(format: "%.1f сек", autoFixUndoWindow)).monospacedDigit()
                    }
                    Slider(value: $autoFixUndoWindow, in: 0.5...3.0, step: 0.1)
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
