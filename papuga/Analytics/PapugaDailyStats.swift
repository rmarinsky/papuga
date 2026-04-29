import Defaults
import Foundation

/// Per-day replacement totals. Persisted in `Defaults` as a flat array keyed
/// by the calendar day (`yyyy-MM-dd`) so the analytics tab can render a
/// 30-day chart and Day / Week / Month / All scopes the way BrowserCat does.
struct PapugaDailyStats: Codable, Equatable, Identifiable, Defaults.Serializable {
    let day: String
    var replacementCount: Int
    var wordsCount: Int
    var secondsSaved: Int

    var id: String { day }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(for date: Date = Date()) -> String {
        isoFormatter.string(from: date)
    }

    var date: Date? {
        Self.isoFormatter.date(from: day)
    }
}

enum PapugaStatsAggregator {
    static func bumpToday(words: Int, seconds: Int, sign: Int = 1) {
        let today = PapugaDailyStats.dayString()
        var history = Defaults[.dailyStatsHistory]
        if let idx = history.firstIndex(where: { $0.day == today }) {
            history[idx].replacementCount = max(0, history[idx].replacementCount + sign)
            history[idx].wordsCount = max(0, history[idx].wordsCount + sign * words)
            history[idx].secondsSaved = max(0, history[idx].secondsSaved + sign * seconds)
        } else if sign > 0 {
            history.append(PapugaDailyStats(
                day: today,
                replacementCount: 1,
                wordsCount: words,
                secondsSaved: seconds
            ))
        }
        // Cap at 365 days, sorted oldest -> newest.
        history.sort { $0.day < $1.day }
        if history.count > 365 {
            history = Array(history.suffix(365))
        }
        Defaults[.dailyStatsHistory] = history
    }

    static func secondsSaved(scope: Scope, history: [PapugaDailyStats]) -> Int {
        let cal = Calendar.current
        let now = Date()
        let cutoff: Date? = {
            switch scope {
            case .day:
                return cal.startOfDay(for: now)
            case .week:
                return cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))
            case .month:
                return cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))
            case .all:
                return nil
            }
        }()
        return history.reduce(0) { acc, entry in
            guard let date = entry.date else { return acc }
            if let cutoff, date < cutoff { return acc }
            return acc + entry.secondsSaved
        }
    }

    static func dailySeries(lastDays: Int, history: [PapugaDailyStats]) -> [(date: Date, seconds: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let map = Dictionary(uniqueKeysWithValues: history.compactMap { entry -> (Date, Int)? in
            guard let date = entry.date else { return nil }
            return (cal.startOfDay(for: date), entry.secondsSaved)
        })
        return (0..<lastDays).reversed().compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (date: date, seconds: map[date] ?? 0)
        }
    }

    static func monthOverMonthDelta(history: [PapugaDailyStats]) -> Double? {
        let cal = Calendar.current
        let now = Date()
        let thisStart = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))
        let prevStart = cal.date(byAdding: .day, value: -59, to: cal.startOfDay(for: now))
        guard let thisStart, let prevStart else { return nil }
        var thisTotal = 0
        var prevTotal = 0
        for entry in history {
            guard let date = entry.date else { continue }
            if date >= thisStart {
                thisTotal += entry.secondsSaved
            } else if date >= prevStart {
                prevTotal += entry.secondsSaved
            }
        }
        guard prevTotal > 0 else { return nil }
        return (Double(thisTotal) - Double(prevTotal)) / Double(prevTotal)
    }

    enum Scope: String, CaseIterable, Identifiable {
        case day, week, month, all
        var id: String { rawValue }

        var label: String {
            switch self {
            case .day: return "Сьогодні"
            case .week: return "Тиждень"
            case .month: return "Місяць"
            case .all: return "Весь час"
            }
        }

        var subtitle: String {
            switch self {
            case .day: return "зекономлено сьогодні"
            case .week: return "зекономлено за тиждень"
            case .month: return "зекономлено за місяць"
            case .all: return "зекономлено всього"
            }
        }
    }
}
