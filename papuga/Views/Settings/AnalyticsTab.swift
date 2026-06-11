import AppKit
import Charts
import Defaults
import SwiftUI

struct AnalyticsTab: View {
    var recommendations: [Recommendation] = []

    @Default(.textReplacementCount) private var textReplacementCount
    @Default(.totalReplacedWords) private var totalReplacedWords
    @Default(.dailyStatsHistory) private var history

    @State private var scope: PapugaStatsAggregator.Scope = .week
    @State private var historyStore = ReplacementHistoryStore.shared

    var body: some View {
        Group {
            if textReplacementCount > 0 || !history.isEmpty {
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(spacing: 16) {
                            heroCard
                            metricRow
                            chartCard
                            bottomRow
                            footer
                        }
                        .padding(20)
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header (scope picker, top-right)

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Огляд")
                .font(.system(size: 20, weight: .bold))
            Spacer()
            Picker("", selection: $scope) {
                ForEach(PapugaStatsAggregator.Scope.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: 340, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    // MARK: - Hero card (compact, horizontal)

    private var heroCard: some View {
        let seconds = PapugaStatsAggregator.secondsSaved(scope: scope, history: history)
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ЧАС НЕ ДРУКОВАНИЙ")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Color("BrandAccentDeep"))

                Text(formatSeconds(seconds))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: seconds)

                Text("≈ \(textReplacementCount) врятованих моментів")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 12) {
                if let delta = PapugaStatsAggregator.monthOverMonthDelta(history: history) {
                    deltaTrend(delta: delta)
                }
                receiptGraphic
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color("BrandTintSoft"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color("BrandTintBorder"), lineWidth: 1)
        )
    }

    private func deltaTrend(delta: Double) -> some View {
        let percent = Int((delta * 100).rounded())
        let isUp = delta >= 0
        return HStack(spacing: 4) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isUp ? Color.green : Color.secondary)
            Text(isUp ? "+\(percent)% проти минулого місяця"
                      : "\(percent)% проти минулого місяця")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var receiptGraphic: some View {
        HStack(spacing: 8) {
            Text("ghbdtn")
                .font(.system(.caption, design: .monospaced))
                .strikethrough(true, color: Color("BrandAccentDeep"))
                .foregroundStyle(Color("BrandAccentDeep").opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.background.secondary)
                )
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(Color("BrandAccentDeep"))
            Text("привіт")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color("BrandAccentDeep"))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color("BrandTintSoft").opacity(0.8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color("BrandTintBorder"), lineWidth: 1)
                        )
                )
        }
    }

    // MARK: - 4 Metric cards (single row)

    private var metricRow: some View {
        HStack(spacing: 12) {
            metricCard(
                systemImage: "keyboard",
                value: "\(textReplacementCount)",
                label: "Замін виконано"
            )
            metricCard(
                systemImage: "textformat",
                value: compactNumber(totalReplacedWords),
                label: "Слів замінено"
            )
            metricCard(
                systemImage: "checkmark.seal",
                value: accuracyText,
                label: "Точність"
            )
            langPairCard
        }
        .frame(maxWidth: .infinity)
    }

    private func metricCard(systemImage: String, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            iconTile(systemImage: systemImage)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.tertiary)
        )
    }

    private var langPairCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            iconTile(systemImage: "globe")
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                langChip("EN")
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color("BrandAccentDeep"))
                langChip("UA")
            }
            Text("Найчастіша пара")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.tertiary)
        )
    }

    private func iconTile(systemImage: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color("BrandTintSoft"))
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color("BrandAccentDeep"))
        }
        .frame(width: 26, height: 26)
    }

    private func langChip(_ code: String) -> some View {
        Text(code)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color("BrandAccentDeep"))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color("BrandTintSoft"))
            )
    }

    // MARK: - Chart (weekly with ramp/ghost/avg)

    private var chartCard: some View {
        let series = PapugaStatsAggregator.dailySeries(lastDays: 7, history: history)
        let maxSeconds = series.map(\.seconds).max() ?? 1
        let avgSeconds = series.isEmpty ? 0 : series.map(\.seconds).reduce(0, +) / series.count
        let today = Calendar.current.startOfDay(for: Date())

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Заміни цього тижня")
                        .font(.system(size: 13, weight: .semibold))
                    Text("зекономлено за день")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if avgSeconds > 0 {
                    Text("сер. \(formatSecondsShort(avgSeconds))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Chart {
                ForEach(series, id: \.date) { point in
                    let isToday = Calendar.current.startOfDay(for: point.date) == today
                    let isPeak = point.seconds == maxSeconds && point.seconds > 0
                    if point.seconds > 0 {
                        let opacity = isToday ? 1.0 : max(0.25, 0.25 + 0.6 * Double(point.seconds) / Double(max(maxSeconds, 1)))
                        BarMark(
                            x: .value("День", point.date, unit: .day),
                            y: .value("Секунди", point.seconds)
                        )
                        .foregroundStyle(Color("BrandAccent").opacity(opacity))
                        .cornerRadius(4, style: .continuous)
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            if isPeak {
                                Text(formatSecondsShort(point.seconds))
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Color("BrandAccentDeep"))
                                    )
                            }
                        }
                    } else {
                        // Ghost bar for zero days
                        BarMark(
                            x: .value("День", point.date, unit: .day),
                            y: .value("Секунди", max(maxSeconds / 20, 1))
                        )
                        .foregroundStyle(Color.secondary.opacity(0.12))
                        .cornerRadius(4, style: .continuous)
                    }
                }

                // Dashed average line
                if avgSeconds > 0 {
                    RuleMark(y: .value("Середнє", avgSeconds))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                }

                // Hairline baseline
                RuleMark(y: .value("Baseline", 0))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.2))
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                        .font(.system(size: 9))
                }
            }
            .frame(height: 120)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.tertiary)
        )
    }

    // MARK: - Bottom row (Suggestions preview + Recent fixes)

    private var bottomRow: some View {
        HStack(alignment: .top, spacing: 12) {
            suggestionsCard
            recentFixesCard
        }
    }

    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Поради")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !recommendations.isEmpty {
                    sectionLink("Усі ›", to: .suggestions)
                }
            }

            if let top = recommendations.first {
                suggestionMini(top)
                if recommendations.count > 1 {
                    sectionLink("+ ще \(recommendations.count - 1) ›", to: .suggestions)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("Поки що немає порад")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.tertiary)
        )
    }

    private func suggestionMini(_ rec: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rec.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Text(rec.displaySubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Button { RecommendationEngine.apply(rec) } label: {
                    Text("Застосувати").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color("BrandAccentDeep"))

                Button { RecommendationEngine.dismiss(rec) } label: {
                    Text("Відхилити").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color("BrandTintSoft"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color("BrandTintBorder"), lineWidth: 1)
        )
    }

    private var recentFixesCard: some View {
        let recent = Array(historyStore.entries.prefix(4))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Останні заміни")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !recent.isEmpty {
                    sectionLink("Усі ›", to: .history)
                }
            }

            if recent.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("Ще немає замін")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ForEach(recent) { entry in
                    recentRow(entry)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.tertiary)
        )
    }

    private func recentRow(_ entry: ReplacementHistoryEntry) -> some View {
        HStack(spacing: 8) {
            appIcon(for: entry.bundleID)
            miniReceipt(original: entry.original, converted: entry.converted)
            Spacer(minLength: 6)
            if let name = appName(for: entry.bundleID) {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(shortAgo(entry.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private func miniReceipt(original: String, converted: String) -> some View {
        HStack(spacing: 5) {
            Text(original)
                .font(.system(size: 11, design: .monospaced))
                .strikethrough(true, color: Color("BrandAccentDeep").opacity(0.7))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 8))
                .foregroundStyle(Color("BrandAccentDeep"))
            Text(converted)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func appIcon(for bundleID: String?) -> some View {
        if let bundleID, !bundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 15, height: 15)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 15, height: 15)
        }
    }

    private func sectionLink(_ text: String, to section: HistorySection) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .historyWindowSectionRequest,
                object: nil,
                userInfo: ["section": section]
            )
        } label: {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color("BrandAccentDeep"))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let stat = history.first(where: { $0.date != nil }), let earliest = stat.date {
                Text("Облік від \(earliest.formatted(date: .abbreviated, time: .omitted))")
            }
            Spacer()
            Text("Всього: \(formatSeconds(PapugaStatsAggregator.secondsSaved(scope: .all, history: history)))")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Поки що немає статистики")
                .font(.headline)
            Text("Як тільки папуга зробить першу заміну, тут зʼявляться графіки і лічильники.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Helpers

    private var accuracyText: String {
        var applied = 0
        var undone = 0
        for entry in historyStore.entries {
            switch entry.kind {
            case .autoFixApplied: applied += 1
            case .autoFixUndone: undone += 1
            case .manualSwitch: break
            }
        }
        let denom = applied + undone
        guard denom > 0 else { return "—" }
        return "\(Int((Double(applied) / Double(denom) * 100).rounded()))%"
    }

    private func appName(for bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init)?.capitalized
    }

    private func compactNumber(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        return String(format: k < 10 ? "%.1fk" : "%.0fk", k)
    }

    private func shortAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(max(s, 0)) с" }
        if s < 3600 { return "\(s / 60) хв" }
        if s < 86400 { return "\(s / 3600) год" }
        return "\(s / 86400) дн"
    }

    private func formatSeconds(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) с" }
        if seconds < 3600 {
            let m = seconds / 60
            let s = seconds % 60
            return s == 0 ? "\(m) хв" : "\(m) хв \(s) с"
        }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m == 0 ? "\(h) год" : "\(h) год \(m) хв"
    }

    private func formatSecondsShort(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)с" }
        if seconds < 3600 { return "\(seconds / 60)хв" }
        return "\(seconds / 3600)г"
    }
}
