import Foundation

enum HistoryTimeRange: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Сьогодні"
        case .week: return "Тиждень"
        case .month: return "Місяць"
        case .all: return "Увесь час"
        }
    }

    var clearScopeTitle: String {
        switch self {
        case .today: return "за сьогодні"
        case .week: return "за тиждень"
        case .month: return "за місяць"
        case .all: return "за увесь час"
        }
    }

    func contains(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        switch self {
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .week:
            return isWithinLast(days: 7, date: date, now: now, calendar: calendar)
        case .month:
            return isWithinLast(days: 30, date: date, now: now, calendar: calendar)
        case .all:
            return true
        }
    }

    private func isWithinLast(
        days: Int,
        date: Date,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let todayStart = calendar.startOfDay(for: now)
        guard let lowerBound = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) else {
            return true
        }
        return date >= lowerBound
    }
}
