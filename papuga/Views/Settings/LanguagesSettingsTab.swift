import Defaults
import SwiftUI

struct LanguagesSettingsTab: View {
    @Environment(LayoutManager.self) private var layoutManager
    @Default(.layoutOrder) private var layoutOrder
    @Default(.disabledLayouts) private var disabledLayouts

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            List {
                Section {
                    if enabledLayouts.isEmpty {
                        Text("Жодної активної розкладки.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(enabledLayouts) { layout in
                        layoutRow(layout, enabled: true)
                    }
                    .onMove(perform: moveEnabled)
                } header: {
                    Text("Активні — Papuga перемикає між ними по колу")
                }

                if !disabledLayoutInfos.isEmpty {
                    Section("Доступні") {
                        ForEach(disabledLayoutInfos) { layout in
                            layoutRow(layout, enabled: false)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { layoutManager.reloadLayouts() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Розкладки, між якими Papuga перемикає текст")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if enabledLayouts.count < 2 {
                Label("Увімкни щонайменше дві розкладки, щоб перемикання працювало.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func layoutRow(_ layout: InputSourceInfo, enabled: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color("BrandTintSoft"))
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color("BrandAccentDeep"))
            }
            .frame(width: 24, height: 24)

            Text(layout.name)
                .foregroundStyle(enabled ? .primary : .secondary)

            Spacer()

            Toggle("", isOn: enabledBinding(for: layout))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Derived lists

    private var enabledLayouts: [InputSourceInfo] {
        let disabled = Set(disabledLayouts)
        let order = layoutOrder
        let rank: (String) -> Int = { id in order.firstIndex(of: id) ?? Int.max }
        return layoutManager.availableLayouts
            .filter { !disabled.contains($0.id) }
            .sorted { rank($0.id) < rank($1.id) }
    }

    private var disabledLayoutInfos: [InputSourceInfo] {
        let disabled = Set(disabledLayouts)
        return layoutManager.availableLayouts
            .filter { disabled.contains($0.id) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: - Mutations

    private func enabledBinding(for layout: InputSourceInfo) -> Binding<Bool> {
        Binding(
            get: { !disabledLayouts.contains(layout.id) },
            set: { isOn in
                if isOn {
                    disabledLayouts.removeAll { $0 == layout.id }
                    if !layoutOrder.contains(layout.id) {
                        layoutOrder.append(layout.id)
                    }
                } else if !disabledLayouts.contains(layout.id) {
                    disabledLayouts.append(layout.id)
                }
            }
        )
    }

    private func moveEnabled(from source: IndexSet, to destination: Int) {
        var ids = enabledLayouts.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        let disabledIDs = layoutOrder.filter { disabledLayouts.contains($0) }
        layoutOrder = ids + disabledIDs.filter { !ids.contains($0) }
    }
}
