import Charts
import Defaults
import SwiftUI

struct AnalyticsTab: View {
    @Default(.textReplacementCount) private var textReplacementCount
    @Default(.totalReplacedWords) private var totalReplacedWords
    @Default(.dailyStatsHistory) private var history

    @State private var scope: PapugaStatsAggregator.Scope = .month

    var body: some View {
        Group {
            if textReplacementCount > 0 || !history.isEmpty {
                ScrollView {
                    VStack(spacing: 20) {
                        heroCard
                        chartCard
                        breakdownCard
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
        return VStack(spacing: 12) {
            Picker("", selection: $scope) {
                ForEach(PapugaStatsAggregator.Scope.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(spacing: 6) {
                Text(formatSeconds(seconds))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: seconds)

                Text(scope.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if scope == .month, let delta = PapugaStatsAggregator.monthOverMonthDelta(history: history) {
                    deltaPill(delta: delta)
                }
            }
            .padding(.vertical, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.tertiary)
        )
    }

    private func deltaPill(delta: Double) -> some View {
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

    // MARK: - Chart

    private var chartCard: some View {
        let series = PapugaStatsAggregator.dailySeries(lastDays: 30, history: history)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Останні 30 днів")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Chart {
                ForEach(series, id: \.date) { point in
                    BarMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Seconds", point.seconds)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(3)
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                        .font(.system(size: 9))
                }
            }
            .frame(height: 140)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.tertiary)
        )
    }

    // MARK: - Breakdown

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Підсумок")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            row(label: "Заміни виконано", value: textReplacementCount)
            row(label: "Замінено слів", value: totalReplacedWords)
            row(label: "Зекономив секунд життя", value: estimatedSecondsSaved)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.tertiary)
        )
    }

    private func row(label: String, value: Int) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text("\(value)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
        .padding(.vertical, 4)
    }

    private var estimatedSecondsSaved: Int {
        Constants.estimatedSecondsSaved(replacementCount: textReplacementCount, totalWords: totalReplacedWords)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let earliest = history.first(where: { $0.date != nil })?.date {
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
}
