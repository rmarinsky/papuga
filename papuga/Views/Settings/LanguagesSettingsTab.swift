import Defaults
import SwiftUI

struct LanguagesSettingsTab: View {
    @Default(.autoFixAlgorithm) private var autoFixAlgorithm
    @Default(.autoFixThreshold) private var autoFixThreshold

    var body: some View {
        Form {
            Section("Визначення мови") {
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
        }
        .formStyle(.grouped)
        .onAppear {
            if let selected = LanguageScorerAlgorithm(rawValue: autoFixAlgorithm),
               selected.isImplemented {
                return
            }
            autoFixAlgorithm = LanguageScorerAlgorithm.appleNL.rawValue
        }
    }
}
