import XCTest
@testable import papuga

final class HistoryTimeRangeTests: XCTestCase {
    func test_tabsAreOrderedFromTodayToAllTime() {
        XCTAssertEqual(
            HistoryTimeRange.allCases.map(\.title),
            ["Сьогодні", "Тиждень", "Місяць", "Увесь час"]
        )
    }

    func test_todayOnlyIncludesCurrentCalendarDay() {
        let calendar = utcCalendar
        let now = date(year: 2026, month: 6, day: 13, hour: 16)

        XCTAssertTrue(HistoryTimeRange.today.contains(
            date(year: 2026, month: 6, day: 13, hour: 1),
            now: now,
            calendar: calendar
        ))
        XCTAssertFalse(HistoryTimeRange.today.contains(
            date(year: 2026, month: 6, day: 12, hour: 23),
            now: now,
            calendar: calendar
        ))
    }

    func test_weekIncludesSevenCalendarDaysIncludingToday() {
        let calendar = utcCalendar
        let now = date(year: 2026, month: 6, day: 13, hour: 16)

        XCTAssertTrue(HistoryTimeRange.week.contains(
            date(year: 2026, month: 6, day: 7, hour: 0),
            now: now,
            calendar: calendar
        ))
        XCTAssertFalse(HistoryTimeRange.week.contains(
            date(year: 2026, month: 6, day: 6, hour: 23),
            now: now,
            calendar: calendar
        ))
    }

    func test_monthIncludesThirtyCalendarDaysIncludingToday() {
        let calendar = utcCalendar
        let now = date(year: 2026, month: 6, day: 13, hour: 16)

        XCTAssertTrue(HistoryTimeRange.month.contains(
            date(year: 2026, month: 5, day: 15, hour: 0),
            now: now,
            calendar: calendar
        ))
        XCTAssertFalse(HistoryTimeRange.month.contains(
            date(year: 2026, month: 5, day: 14, hour: 23),
            now: now,
            calendar: calendar
        ))
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.calendar = utcCalendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }
}
