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
    /// One-time backfill: when the daily-history schema first ships, the
    /// legacy `textReplacementCount` / `totalReplacedWords` counters reflect
    /// activity going back to install date but the new history is empty,
    /// causing the hero card to show ~0 while the breakdown card shows the
    /// lifetime total. Stash all the legacy activity into today's bucket so
    /// the All-time and Month scopes pick it up. Today's bar will be tall
    /// once after upgrade; from then on, daily entries accumulate naturally.
    static func migrateLegacyCountersIfNeeded() {
        guard !Defaults[.dailyStatsHistoryMigrated] else { return }
        let legacyCount = Defaults[.textReplacementCount]
        let legacyWords = Defaults[.totalReplacedWords]
        guard legacyCount > 0 else {
            Defaults[.dailyStatsHistoryMigrated] = true
            return
        }
        let legacySeconds = Constants.estimatedSecondsSaved(replacementCount: legacyCount, totalWords: legacyWords)
        let today = PapugaDailyStats.dayString()
        var history = Defaults[.dailyStatsHistory]
        if let idx = history.firstIndex(where: { $0.day == today }) {
            history[idx].replacementCount += legacyCount
            history[idx].wordsCount += legacyWords
            history[idx].secondsSaved += legacySeconds
        } else {
            history.append(PapugaDailyStats(
                day: today,
                replacementCount: legacyCount,
                wordsCount: legacyWords,
                secondsSaved: legacySeconds
            ))
        }
        history.sort { $0.day < $1.day }
        Defaults[.dailyStatsHistory] = history
        Defaults[.dailyStatsHistoryMigrated] = true
    }

    /// Recovery safety net. The analytics hero number lives in
    /// `dailyStatsHistory` (UserDefaults), which — unlike AppCat's `stats.json`
    /// or Diduny's on-the-fly recompute — is NOT rebuildable from anything
    /// durable. A lost or swapped preferences plist (reinstall, bundle-ID change
    /// dev↔release, sandbox-container migration, prefs reset) silently zeroes the
    /// "зекономлено" total even though every replacement is still on disk in
    /// `replacement-history.jsonl`. When the daily history is empty but the
    /// replacement log survives, rebuild the per-day stats from it so the number
    /// recovers instead of resetting to zero. Mirrors AppCat's
    /// `StatsManager.backfillIfNeeded()`.
    ///
    /// Empty-only by design: it never overwrites a non-empty history, so it can't
    /// fight an intentional reset, and it can't be tripped by `jsonl` retention
    /// pruning (default 1 month) clobbering the 365-day analytics window.
    static func rebuildDailyStatsFromHistoryIfNeeded(using store: ReplacementHistoryStore = .shared) {
        guard Defaults[.dailyStatsHistory].isEmpty else { return }
        let rebuilt = dailyStats(from: store.loadEntriesSync())
        guard !rebuilt.isEmpty else { return }
        Defaults[.dailyStatsHistory] = rebuilt
        // The jsonl already reflects real lifetime activity, so mark the legacy
        // counter migration done to avoid double-counting it into today.
        Defaults[.dailyStatsHistoryMigrated] = true
    }

    /// Aggregates raw replacement-log entries into per-day totals, netting out
    /// undone auto-fixes exactly as the live counters do (`reverseReplacement`
    /// subtracts the same word count that the apply added). Word counts come from
    /// the stored `converted` text; entries truncated at 80 chars slightly
    /// undercount, which keeps the recovered number conservative.
    static func dailyStats(from entries: [ReplacementHistoryEntry]) -> [PapugaDailyStats] {
        var byDay: [String: PapugaDailyStats] = [:]
        for entry in entries {
            let sign = entry.kind == .autoFixUndone ? -1 : 1
            let words = max(1, entry.converted.split(separator: " ").count)
            let seconds = Constants.secondsSaved(words: words)
            let day = PapugaDailyStats.dayString(for: entry.timestamp)
            var stat = byDay[day] ?? PapugaDailyStats(day: day, replacementCount: 0, wordsCount: 0, secondsSaved: 0)
            stat.replacementCount += sign
            stat.wordsCount += sign * words
            stat.secondsSaved += sign * seconds
            byDay[day] = stat
        }
        return byDay.values
            .filter { $0.replacementCount > 0 }
            .map { PapugaDailyStats(
                day: $0.day,
                replacementCount: max(0, $0.replacementCount),
                wordsCount: max(0, $0.wordsCount),
                secondsSaved: max(0, $0.secondsSaved)
            ) }
            .sorted { $0.day < $1.day }
    }

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
