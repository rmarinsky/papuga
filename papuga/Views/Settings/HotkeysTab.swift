import SwiftUI
import Defaults
import KeyboardShortcuts

struct HotkeysTab: View {
    @Default(.useDoublePress) private var useDoublePress
    @Default(.doublePressInterval) private var doublePressInterval
    @Default(.doublePressShortcut) private var doublePressShortcut

    var body: some View {
        Form {
            Section("Режим активації") {
                Picker("Спосіб", selection: $useDoublePress) {
                    Text("Подвійне натискання (рекомендовано)").tag(true)
                    Text("Користувацька комбінація").tag(false)
                }
                .pickerStyle(.radioGroup)
            }

            if useDoublePress {
                Section("Подвійне натискання") {
                    Picker("Комбінація", selection: $doublePressShortcut) {
                        ForEach(DoublePressShortcutPreset.allCases, id: \.rawValue) { preset in
                            Text(preset.title).tag(preset.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Перемикання вперед: \(selectedPreset.title) × 2")
                        .font(.callout)

                    HStack {
                        Text("Інтервал:")
                        Slider(value: $doublePressInterval, in: 0.2...0.8, step: 0.05)
                        Text("\(doublePressInterval, specifier: "%.2f") с")
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                }
            } else {
                Section("Користувацькі комбінації") {
                    HStack {
                        Text("Вперед:")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .switchForward)
                    }
                }
            }

            Section("Дії") {
                shortcutRow("Скасувати останню заміну", name: .undoLastFix)
                shortcutRow("Увімкнути / вимкнути автозаміну", name: .toggleAutoFix)
                shortcutRow("Відкрити Papuga", name: .openPapuga)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ title: String, name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(title)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }

    private var selectedPreset: DoublePressShortcutPreset {
        DoublePressShortcutPreset(rawValue: doublePressShortcut) ?? .optionShift
    }
}
