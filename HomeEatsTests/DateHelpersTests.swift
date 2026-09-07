import XCTest
@testable import HomeEats

final class DateHelpersTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1 // Sunday
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testStartOfMonth() {
        let midMonth = date(2026, 9, 17)
        let start = calendar.startOfMonth(for: midMonth)
        let comps = calendar.dateComponents([.year, .month, .day], from: start)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 9)
        XCTAssertEqual(comps.day, 1)
    }

    func testGridDaysCoversFullMonthInCompleteWeeks() {
        // September 2026: 1st is a Tuesday, so the grid should start on
        // Sunday Aug 30 and end on a Saturday that covers Sep 30.
        let days = calendar.gridDays(forMonthContaining: date(2026, 9, 15))
        XCTAssertEqual(days.count % 7, 0, "Grid must be made of whole weeks")

        let first = days.first!
        let last = days.last!
        XCTAssertEqual(calendar.component(.weekday, from: first), 1, "Grid should start on a Sunday")
        XCTAssertEqual(calendar.component(.weekday, from: last), 7, "Grid should end on a Saturday")

        // Every day in September must be present in the grid.
        for day in 1...30 {
            let expected = date(2026, 9, day)
            XCTAssertTrue(days.contains { calendar.isDate($0, inSameDayAs: expected) })
        }
    }

    func testOrderedWeekdaySymbolsStartsOnFirstWeekday() {
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1
        XCTAssertEqual(sundayFirst.orderedVeryShortWeekdaySymbols.first, sundayFirst.veryShortWeekdaySymbols[0])

        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2
        XCTAssertEqual(mondayFirst.orderedVeryShortWeekdaySymbols.first, mondayFirst.veryShortWeekdaySymbols[1])
    }
}
