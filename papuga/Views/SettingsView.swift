import SwiftUI
import Defaults
import LaunchAtLogin
import KeyboardShortcuts

struct SettingsView: View {
    @State private var positionedWindowID: ObjectIdentifier?

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label("Загальні", systemImage: "gear")
                }

            HotkeysTab()
                .tabItem {
                    Label("Гарячі клавіші", systemImage: "command")
                }

            AnalyticsTab()
                .tabItem {
                    Label("Аналітика", systemImage: "chart.bar")
                }

            AboutTab()
                .tabItem {
                    Label("Про програму", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 320)
        .background(
            SettingsWindowAccessor { window in
                guard let window else { return }
                let id = ObjectIdentifier(window)
                guard positionedWindowID != id else { return }
                positionedWindowID = id

                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        )
        .onDisappear {
            positionedWindowID = nil
        }
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @Default(.showMenuBarIcon) private var showMenuBarIcon
    @Default(.switchResultMode) private var switchResultMode
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false

    var body: some View {
        Form {
            Section("Сервіс") {
                LaunchAtLogin.Toggle("Запускати при вході в систему")
                Toggle("Показувати іконку в меню-барі", isOn: $showMenuBarIcon)
            }

            Section("Результат перемикання") {
                Picker("Дія", selection: $switchResultMode) {
                    ForEach(SwitchResultMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedSwitchResultMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Дозволи") {
                PermissionRow(
                    icon: "accessibility",
                    title: "Спеціальні можливості",
                    description: "Симуляція Cmd+C та Cmd+V",
                    isGranted: $accessibilityGranted,
                    permissionType: .accessibility
                )
                PermissionRow(
                    icon: "keyboard",
                    title: "Моніторинг введення",
                    description: "Відстеження гарячих клавіш",
                    isGranted: $inputMonitoringGranted,
                    permissionType: .inputMonitoring
                )
            }
        }
        .formStyle(.grouped)
        .task {
            checkPermissionsPassive()
        }
    }

    private func checkPermissionsPassive() {
        accessibilityGranted = PermissionManager.shared.checkAccessibilityPermission()
        inputMonitoringGranted = PermissionManager.shared.checkInputMonitoringPermission()
    }

    private var selectedSwitchResultMode: SwitchResultMode {
        SwitchResultMode(rawValue: switchResultMode) ?? .copyAndPaste
    }
}

// MARK: - Analytics Tab

private struct AnalyticsTab: View {
    @Default(.textReplacementCount) private var textReplacementCount
    @Default(.totalReplacedWords) private var totalReplacedWords
    @Default(.analyticsDayStamp) private var analyticsDayStamp
    @Default(.savedSecondsToday) private var savedSecondsToday

    var body: some View {
        Form {
            Section("Підсумок") {
                HStack {
                    Text("Сьогодні зекономлено секунд")
                    Spacer()
                    Text("\(todaySavedSeconds)")
                        .monospacedDigit()
                }

                HStack {
                    Text("Зекономив секунд життя")
                    Spacer()
                    Text("\(estimatedSecondsSaved)")
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var averageWordsPerReplacement: Double {
        guard textReplacementCount > 0 else { return 0 }
        return Double(totalReplacedWords) / Double(textReplacementCount)
    }

    private var estimatedSecondsSaved: Int {
        let estimated = Double(textReplacementCount) * averageWordsPerReplacement * Constants.estimatedManualReplacementSecondsPerWord
        return Int(estimated.rounded())
    }

    private var todaySavedSeconds: Int {
        analyticsDayStamp == currentDayStamp ? savedSecondsToday : 0
    }

    private var currentDayStamp: String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

// MARK: - Hotkeys Tab

private struct HotkeysTab: View {
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
        }
        .formStyle(.grouped)
    }

    private var selectedPreset: DoublePressShortcutPreset {
        DoublePressShortcutPreset(rawValue: doublePressShortcut) ?? .optionShift
    }
}

// MARK: - About Tab

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text(Constants.appName)
                .font(.title)
                .bold()

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                Text("Версія \(version) (\(build))")
                    .foregroundStyle(.secondary)
            }

            Text("Перемикач розкладки клавіатури для macOS")
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 200)

            Text("Автор: Roman Marinskyi")
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
