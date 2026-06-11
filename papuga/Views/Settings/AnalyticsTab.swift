import Charts
import Defaults
import SwiftUI

struct AnalyticsTab: View {
    @Default(.textReplacementCount) private var textReplacementCount
    @Default(.totalReplacedWords) private var totalReplacedWords
    @Default(.dailyStatsHistory) private var history

    @State private var scope: PapugaStatsAggregator.Scope = .week

    var body: some View {
        Group {
            if textReplacementCount > 0 || !history.isEmpty {
                ScrollView {
                    VStack(spacing: 16) {
                        heroCard
                        metricGrid
                        chartCard
                        footer
                    }
                    .padding(16)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hero card

    private var heroCard: some View {
        let seconds = PapugaStatsAggregator.secondsSaved(scope: scope, history: history)
        return VStack(spacing: 10) {
            // Eyebrow
            Text("ЧАС НЕ ДРУКОВАНИЙ")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Color("BrandAccentDeep"))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Scope picker
            Picker("", selection: $scope) {
                ForEach(PapugaStatsAggregator.Scope.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Number + subline + trend
            VStack(spacing: 4) {
                Text(formatSeconds(seconds))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: seconds)

                Text(scope.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Папуга вже постарався за тебе")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if scope == .month, let delta = PapugaStatsAggregator.monthOverMonthDelta(history: history) {
                    deltaTrend(delta: delta)
                }
            }
            .padding(.vertical, 4)

            // Receipt graphic
            receiptGraphic
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
            Text(isUp ? "+\(percent)% проти попереднього місяця"
                      : "\(percent)% проти попереднього місяця")
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
        .padding(.top, 4)
    }

    // MARK: - 4 Metric cards

    private var metricGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            metricCard(
                systemImage: "arrow.left.arrow.right.circle",
                value: "\(textReplacementCount)",
                label: "Замін виконано"
            )
            metricCard(
                systemImage: "text.bubble",
                value: "\(totalReplacedWords)",
                label: "Слів замінено"
            )
            metricCard(
                systemImage: "timer",
                value: formatSeconds(estimatedSecondsSaved),
                label: "Зекономлено часу"
            )
            langPairCard
        }
    }

    private func metricCard(systemImage: String, value: String, label: String) -> some View {
        HStack(spacing: 12) {
            iconTile(systemImage: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.tertiary)
        )
    }

    private var langPairCard: some View {
        HStack(spacing: 12) {
            iconTile(systemImage: "globe")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    langChip("EN")
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color("BrandAccentDeep"))
                    langChip("UA")
                }
                Text("В обидва боки")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("Останні 7 днів")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Chart {
                ForEach(series, id: \.date) { point in
                    let isToday = Calendar.current.startOfDay(for: point.date) == today
                    if point.seconds > 0 {
                        let opacity = isToday ? 1.0 : max(0.25, 0.25 + 0.6 * Double(point.seconds) / Double(max(maxSeconds, 1)))
                        BarMark(
                            x: .value("День", point.date, unit: .day),
                            y: .value("Секунди", point.seconds)
                        )
                        .foregroundStyle(Color("BrandAccent").opacity(opacity))
                        .cornerRadius(4, style: .continuous)
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            if isToday {
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

    private var estimatedSecondsSaved: Int {
        Constants.estimatedSecondsSaved(replacementCount: textReplacementCount, totalWords: totalReplacedWords)
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
