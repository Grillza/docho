import XCTest
@testable import Docho

/// Cases from Android's FetchIntervalTest, so both apps predict the same day.
final class ReleaseScheduleTests: XCTestCase {
    private func day(_ s: String) -> Day {
        let p = s.split(separator: "-").map { Int($0)! }
        return Day(year: p[0], month: p[1], day: p[2])
    }

    private func next(today: String, _ days: [Day], perDay: Int = 1) -> Day {
        let all = days.flatMap { Array(repeating: $0, count: perDay) }
        return ReleaseSchedule.estimate(uploads: all, fetches: all, today: day(today)).nextCheck(today: day(today))
    }

    private func every(_ step: Int, from: String, to: String) -> [Day] {
        Array(stride(from: day(from).index, through: day(to).index, by: step).map(Day.init(index:)))
    }

    func testDayArithmetic() {
        XCTAssertEqual(day("1970-01-01").index, 0)
        XCTAssertEqual(day("2020-02-29").description, "2020-02-29")
        XCTAssertEqual(day("2020-01-20").isoWeekday, 1) // a Monday
        XCTAssertEqual(day("2020-02-10").lastOfMonth, day("2020-02-29"))
        XCTAssertEqual(day("2019-12-01").plusMonths(1), day("2020-01-01"))
        XCTAssertEqual(day("2020-01-01").plusMonths(-1), day("2019-12-01"))
        XCTAssertEqual(floorMod(-3, 7), 4)
    }

    func testDefaultsToSevenDaysWithoutEnoughReleaseDays() {
        let sameDay = Array(repeating: day("2020-01-02"), count: 50)
        XCTAssertEqual(ReleaseSchedule.estimate(uploads: sameDay, fetches: sameDay, today: day("2020-03-01")).interval, 7)
    }

    func testFollowsTheRecentInterval() {
        let old = (1...5).map { day("2020-01-01").plus($0 * 7) }
        let new = (1...10).map { old.last!.plus($0) }
        XCTAssertEqual(ReleaseSchedule.estimate(uploads: old + new, fetches: old + new, today: day("2020-03-01")).interval, 1)
    }

    func testFollowsAFewFixedWeekdays() {
        let mondaysAndThursdays = every(1, from: "2019-12-02", to: "2020-01-20").filter { [1, 4].contains($0.isoWeekday) }
        let schedule = ReleaseSchedule.estimate(uploads: mondaysAndThursdays, fetches: mondaysAndThursdays, today: day("2020-01-21"))
        XCTAssertEqual(schedule.pattern, .weekdays([1, 4]))
        XCTAssertEqual(next(today: "2020-01-21", mondaysAndThursdays), day("2020-01-23"))
    }

    func testFollowsADayOfTheMonth() {
        let days = ["2019-09-15", "2019-10-15", "2019-11-14", "2019-12-15", "2020-01-16"].map(day)
        XCTAssertEqual(next(today: "2020-01-20", days, perDay: 2), day("2020-02-15"))
    }

    func testFollowsTheLastDayOfTheMonth() {
        let days = ["2019-09-30", "2019-10-31", "2019-11-30", "2019-12-31", "2020-01-31"].map(day)
        XCTAssertEqual(next(today: "2020-02-05", days, perDay: 2), day("2020-02-29"))
    }

    func testFollowsTwoDaysOfTheMonth() {
        let days = ["2019-10-01", "2019-10-15", "2019-11-01", "2019-11-16", "2019-12-01", "2019-12-15", "2020-01-01", "2020-01-15"].map(day)
        let twice = days + days
        let schedule = ReleaseSchedule.estimate(uploads: twice, fetches: twice, today: day("2020-01-20"))
        XCTAssertEqual(schedule.pattern, .daysOfMonth([1, 15]))
        XCTAssertEqual(next(today: "2020-01-20", days, perDay: 2), day("2020-02-01"))
    }

    func testFollowsAWeekdayOfTheMonth() {
        let firstSaturdays = ["2019-09-07", "2019-10-05", "2019-11-02", "2019-12-07", "2020-01-04"].map(day)
        XCTAssertEqual(next(today: "2020-01-10", firstSaturdays, perDay: 2), day("2020-02-01"))
    }

    func testFollowsAWeekdayOfTheLastWeek() {
        let lastFridays = ["2019-09-27", "2019-10-25", "2019-11-29", "2019-12-27", "2020-01-31"].map(day)
        XCTAssertEqual(next(today: "2020-02-03", lastFridays, perDay: 2), day("2020-02-28"))
    }

    func testFollowsBatches() {
        // Three days of releases every three weeks
        let batches = every(21, from: "2019-09-02", to: "2019-12-16").flatMap { start in (0...2).map { start.plus($0) } }
        let schedule = ReleaseSchedule.estimate(uploads: batches, fetches: batches, today: day("2019-12-20"))
        XCTAssertEqual(schedule.pattern, .batches(every: 21, onSchedule: day("2019-12-16"), length: 3))
        XCTAssertEqual(schedule.interval, 21)
    }

    func testChecksAgainAroundWhenAnEarlierBreakEnded() {
        let days = every(7, from: "2019-01-02", to: "2019-03-27") + every(7, from: "2019-07-03", to: "2019-09-25")
        XCTAssertEqual(next(today: "2019-12-20", days), day("2019-12-25"))
        XCTAssertEqual(next(today: "2019-12-26", days), day("2020-01-01"))
    }

    func testKeepsCheckingOnTheExpectedDay() {
        XCTAssertEqual(next(today: "2020-01-01", every(7, from: "2019-12-04", to: "2019-12-25")), day("2020-01-01"))
    }

    func testSpreadsOutChecksDuringAHiatus() {
        XCTAssertEqual(next(today: "2020-01-01", every(7, from: "2019-09-11", to: "2019-10-02")), day("2020-01-22"))
    }

    func testIgnoresChaptersDatedInTheFuture() {
        let days = every(7, from: "2019-12-04", to: "2019-12-25") + [day("2020-06-01")]
        XCTAssertEqual(next(today: "2020-01-01", days), day("2020-01-01"))
    }
}
