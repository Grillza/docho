import Foundation

// A port of Android's ReleaseSchedule and ReleasePattern (domain/.../manga/interactor), so the
// hourglass next to In library predicts the same day on both apps.

/// A calendar day, counted from 1970-01-01, for release arithmetic (kotlinx's LocalDate).
struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
    let index: Int

    init(index: Int) { self.index = index }

    init(year: Int, month: Int, day: Int) {
        // Howard Hinnant's days_from_civil.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        index = era * 146_097 + doe - 719_468
    }

    /// The day `date` falls on in `calendar`'s time zone.
    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    var civil: (year: Int, month: Int, day: Int) {
        // Howard Hinnant's civil_from_days.
        let z = index + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    var day: Int { civil.day }
    /// ISO weekday: Monday is 1, Sunday 7. 1970-01-01 was a Thursday.
    var isoWeekday: Int { floorMod(index + 3, 7) + 1 }

    func plus(_ days: Int) -> Day { Day(index: index + days) }
    func minus(_ days: Int) -> Day { Day(index: index - days) }
    func daysUntil(_ other: Day) -> Int { other.index - index }

    var firstOfMonth: Day { let c = civil; return Day(year: c.year, month: c.month, day: 1) }
    var lastOfMonth: Day { firstOfMonth.plusMonths(1).minus(1) }

    /// The first of the month `months` from this one (only used on firsts of months).
    func plusMonths(_ months: Int) -> Day {
        let c = civil
        let total = c.year * 12 + (c.month - 1) + months
        return Day(year: Int(floor(Double(total) / 12)), month: floorMod(total, 12) + 1, day: c.day)
    }

    static func < (a: Day, b: Day) -> Bool { a.index < b.index }

    var description: String { let c = civil; return String(format: "%04d-%02d-%02d", c.year, c.month, c.day) }
}

/// Kotlin's `mod`: the remainder with the divisor's sign, so never negative for a positive divisor.
func floorMod(_ a: Int, _ b: Int) -> Int {
    let r = a % b
    return r != 0 && (r < 0) != (b < 0) ? r + b : r
}

private func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

private extension Array where Element == Int {
    var median: Int { sorted()[(count - 1) / 2] }
}

/// The days an entry is expected to release on.
enum ReleasePattern: Equatable, Sendable {
    /// Every `days` days, in step with `onSchedule`.
    case everyDays(Int, onSchedule: Day)
    /// A few fixed ISO weekdays.
    case weekdays(Set<Int>)
    /// `length` days in a row, every `every` days in step with `onSchedule`.
    case batches(every: Int, onSchedule: Day, length: Int)
    /// These days of every month, or a month's last day for those past it.
    case daysOfMonth(Set<Int>)
    /// An ISO weekday of the `week`th week of every month, or its last week for `lastWeek`.
    case weekdayOfMonth(week: Int, weekday: Int)

    static let lastWeek = -1

    /// The first expected release day after `date`.
    func nextAfter(_ date: Day) -> Day {
        switch self {
        case .everyDays(let days, let onSchedule):
            return date.plus(days - floorMod(onSchedule.daysUntil(date), days))
        case .weekdays(let days):
            var day = date.plus(1)
            while !days.contains(day.isoWeekday) { day = day.plus(1) }
            return day
        case .batches(let every, let onSchedule, let length):
            let offset = floorMod(onSchedule.daysUntil(date), every)
            return date.plus(offset + 1 < length ? 1 : every - offset)
        case .daysOfMonth, .weekdayOfMonth:
            var month = date.firstOfMonth
            while true {
                if let day = daysIn(month).sorted().first(where: { $0 > date }) { return day }
                month = month.plusMonths(1)
            }
        }
    }

    /// The last expected release day before `date`.
    func previousBefore(_ date: Day) -> Day {
        switch self {
        case .everyDays(let days, let onSchedule):
            return date.minus(floorMod(onSchedule.daysUntil(date) - 1, days) + 1)
        case .weekdays(let days):
            var day = date.minus(1)
            while !days.contains(day.isoWeekday) { day = day.minus(1) }
            return day
        case .batches(let every, let onSchedule, let length):
            let dayBefore = date.minus(1)
            let offset = floorMod(onSchedule.daysUntil(dayBefore), every)
            return dayBefore.minus(max(offset - length + 1, 0))
        case .daysOfMonth, .weekdayOfMonth:
            var month = date.firstOfMonth
            while true {
                if let day = daysIn(month).sorted(by: >).first(where: { $0 < date }) { return day }
                month = month.plusMonths(-1)
            }
        }
    }

    /// The expected release day closest to `date`, which a release on `date` stands in for.
    func nearest(_ date: Day) -> Day {
        // Weekday releases are a day or two apart, so one between them is more likely an extra than an early one
        if case .weekdays = self { return date }
        let before = previousBefore(date.plus(1))
        let after = nextAfter(date.minus(1))
        // A release halfway between is taken as late, so the next check comes sooner
        return before.daysUntil(date) <= date.daysUntil(after) ? before : after
    }

    /// The release days in the month starting on `firstOfMonth`, for the monthly patterns.
    private func daysIn(_ firstOfMonth: Day) -> [Day] {
        switch self {
        case .daysOfMonth(let days):
            let lastDay = firstOfMonth.lastOfMonth.day
            return Array(Set(days.map { firstOfMonth.plus(min($0, lastDay) - 1) }))
        case .weekdayOfMonth(let week, let weekday):
            if week == Self.lastWeek {
                let last = firstOfMonth.lastOfMonth
                return [last.minus(floorMod(last.isoWeekday - weekday, 7))]
            }
            let ahead = floorMod(weekday - firstOfMonth.isoWeekday, 7)
            return [firstOfMonth.plus(ahead + (week - 1) * 7)]
        default:
            return []
        }
    }

    // MARK: Detection

    private static let minReleases = 4
    private static let maxWeekdays = 3
    private static let coverage = 0.8
    private static let dayOfMonthTolerance = 3
    private static let monthlyGaps = 26...35
    private static let twiceMonthlyGaps = 12...18
    private static let batchHistory = 40
    private static let batchGap = 2
    private static let batchCount = 6
    private static let minBatches = 3

    /// Finds a calendar pattern a plain day interval can't follow in `days`, newest first: a few
    /// fixed weekdays, days or a weekday of the month, or batches, which can take longer than
    /// `days` to show up in `history`.
    static func detect(_ days: [Day], history: [Day], medianGap: Int) -> ReleasePattern? {
        guard days.count >= minReleases else { return nil }
        // Batches come first, since their days can look like a few weekdays or a monthly schedule
        if let batches = batches(history) { return batches }
        switch medianGap {
        case monthlyGaps: return monthly(days)
        case twiceMonthlyGaps: return twiceMonthly(days)
        default: return weekdays(days, medianGap: medianGap)
        }
    }

    private static func monthly(_ days: [Day]) -> ReleasePattern? {
        let daysOfMonth = days.map(\.day)
        if daysOfMonth.max()! - daysOfMonth.min()! <= dayOfMonthTolerance { return .daysOfMonth([daysOfMonth.median]) }
        // The last day of the month moves between the 28th and the 31st
        if daysOfMonth.allSatisfy({ $0 >= 28 }) { return .daysOfMonth([31]) }
        return weekdayOfMonth(days)
    }

    private static func weekdayOfMonth(_ days: [Day]) -> ReleasePattern? {
        guard let weekday = mostCommon(days, \.isoWeekday) else { return nil }
        // A fifth week isn't in every month, so those days only count as the last week
        if let week = mostCommon(days, { ($0.day - 1) / 7 + 1 }), week < 5 { return .weekdayOfMonth(week: week, weekday: weekday) }
        let inLastWeek = days.filter { $0.day + 7 > $0.lastOfMonth.day }.count
        return Double(inLastWeek) >= Double(days.count) * coverage ? .weekdayOfMonth(week: lastWeek, weekday: weekday) : nil
    }

    private static func twiceMonthly(_ days: [Day]) -> ReleasePattern? {
        let daysOfMonth = days.map(\.day).sorted()
        var split = 1
        for i in 1..<daysOfMonth.count where daysOfMonth[i] - daysOfMonth[i - 1] > daysOfMonth[split] - daysOfMonth[split - 1] {
            split = i
        }
        let halves = [Array(daysOfMonth[..<split]), Array(daysOfMonth[split...])]
        if halves.contains(where: { $0.count < 2 || $0.last! - $0.first! > dayOfMonthTolerance }) { return nil }
        return .daysOfMonth(Set(halves.map(\.median)))
    }

    private static func weekdays(_ days: [Day], medianGap: Int) -> ReleasePattern? {
        var weekdays = Set<Int>()
        var covered = 0
        for (weekday, count) in counts(days, \.isoWeekday).enumerated().sorted(by: { a, b in
            // Most common first; ties keep the order they first appeared in, as Kotlin's stable sort does
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }).map(\.element) {
            if Double(covered) >= Double(days.count) * coverage { break }
            weekdays.insert(weekday)
            covered += count
        }
        // One weekday is a weekly interval, and an irregular schedule spreads over most of the week
        guard (2...maxWeekdays).contains(weekdays.count), Double(covered) >= Double(days.count) * coverage else { return nil }
        // Releasing on several weekdays means more than one release a week
        if medianGap > 7 / weekdays.count + 1 { return nil }
        return .weekdays(weekdays)
    }

    /// Runs of releases a day or two apart, starting at a steady interval and mostly longer than a day.
    private static func batches(_ history: [Day]) -> ReleasePattern? {
        var runs: [[Day]] = []
        for day in history.prefix(batchHistory).reversed() {
            if let last = runs.last?.last, last.daysUntil(day) <= batchGap {
                runs[runs.count - 1].append(day)
            } else {
                runs.append([day])
            }
        }
        let recent = Array(runs.suffix(batchCount))
        if recent.count < minBatches || recent.filter({ $0.count > 1 }).count * 2 < recent.count { return nil }
        let gaps = zip(recent, recent.dropFirst()).map { older, newer in older[0].daysUntil(newer[0]) }
        let every = gaps.median
        let length = recent.map { $0[0].daysUntil($0[$0.count - 1]) + 1 }.median
        if every < length * 2 || gaps.contains(where: { abs($0 - every) > every / 4 }) { return nil }
        return .batches(every: every, onSchedule: recent[recent.count - 1][0], length: length)
    }

    /// Each key's count, in the order keys first appear (Kotlin's groupingBy().eachCount()).
    private static func counts<T: Hashable>(_ days: [Day], _ key: (Day) -> T) -> [(key: T, count: Int)] {
        var order: [T] = []
        var counts: [T: Int] = [:]
        for day in days {
            let k = key(day)
            if counts[k] == nil { order.append(k) }
            counts[k, default: 0] += 1
        }
        return order.map { ($0, counts[$0]!) }
    }

    /// The most common key, if at least `coverage` of the days share it.
    private static func mostCommon<T: Hashable>(_ days: [Day], _ key: (Day) -> T) -> T? {
        let all = counts(days, key)
        guard var best = all.first else { return nil }
        for entry in all where entry.count > best.count { best = entry }
        return Double(best.count) >= Double(days.count) * coverage ? best.key : nil
    }
}

/// How often an entry releases, and so when to expect the next release.
struct ReleaseSchedule: Equatable, Sendable {
    /// Days between releases.
    let interval: Int
    /// The most recent release day, which the next ones are counted from.
    let lastRelease: Day?
    let pattern: ReleasePattern
    /// Days past the expected day a release can still come, from how late recent ones were.
    var lateness = 0
    /// Lengths in days of earlier breaks, which a break like a season's end is expected to last again.
    var pastBreaks: [Int] = []

    static let maxInterval = 28
    private static let defaultInterval = 7
    private static let hiatusCycles = 4
    private static let minReleases = 3
    private static let fewChapters = 8
    private static let fewChaptersReleases = 3
    private static let recentReleases = 10
    private static let phaseReleases = 5

    /// The next day a release is expected, as of `today`. Today counts, so a due release stays due.
    func nextCheck(today: Day) -> Day {
        let anchor = lastRelease ?? today
        let daysSinceRelease = anchor.daysUntil(today)
        let isOnBreak = daysSinceRelease > interval * Self.hiatusCycles
        // Around when earlier breaks ended, this one likely ends too, so the schedule is followed again
        if isOnBreak, !pastBreaks.contains(where: { ($0 - interval...$0 + interval).contains(daysSinceRelease) }) {
            // Past a few missed releases the schedule no longer holds, so checks spread out until it resumes
            let backedOff = backOff(daysSinceRelease)
            let next = anchor.plus(-floorDiv(-daysSinceRelease, backedOff) * backedOff)
            let breakEnd = pastBreaks.map { anchor.plus($0 - interval) }.filter { $0 > today }.min()
            return min(next, breakEnd ?? next)
        }

        let due = pattern.nextAfter(pattern.nearest(anchor))
        if today >= due, today <= due.plus(lateness) { return today }
        var day = due
        while day < today { day = pattern.nextAfter(day) }
        // Months and batches can be further apart than a check should ever wait
        return min(day, today.plus(Self.maxInterval))
    }

    private func backOff(_ daysSinceRelease: Int) -> Int {
        var backedOff = interval
        while backedOff < Self.maxInterval, daysSinceRelease > backedOff * Self.hiatusCycles { backedOff *= 2 }
        return min(backedOff, Self.maxInterval)
    }

    /// Estimates the schedule from chapters' release days, by upload date or else fetch date.
    static func estimate(uploads: [Day?], fetches: [Day], today: Day) -> ReleaseSchedule {
        let recent = uploads.count <= fewChapters ? fewChaptersReleases : recentReleases
        // Sources that date chapters ahead of their release would otherwise pull the schedule into the future
        let latestPlausibleDay = today.plus(1)
        func releaseDays(_ days: [Day]) -> [Day] {
            Array(Set(days.filter { $0 <= latestPlausibleDay })).sorted(by: >)
        }
        let uploadDays = releaseDays(uploads.compactMap { $0 })
        let fetchDays = releaseDays(fetches)
        let history: [Day]
        if uploadDays.count >= minReleases {
            history = uploadDays
        } else if fetchDays.count >= minReleases {
            history = fetchDays
        } else {
            let lastRelease = uploadDays.first ?? fetchDays.first
            return ReleaseSchedule(
                interval: defaultInterval, lastRelease: lastRelease,
                pattern: .everyDays(defaultInterval, onSchedule: lastRelease ?? today)
            )
        }
        let days = Array(history.prefix(recent))

        let gaps = zip(days, days.dropFirst()).map { newer, older in older.daysUntil(newer) }.sorted()
        let medianGap = gaps[(gaps.count - 1) / 2]
        let detected = ReleasePattern.detect(days, history: history, medianGap: medianGap)
        // Within a batch releases are a day apart, but it's the batches that come every so often
        var interval = medianGap
        if case .batches(let every, _, _) = detected { interval = every }
        interval = min(max(interval, 1), maxInterval)
        return ReleaseSchedule(
            interval: interval,
            lastRelease: days[0],
            pattern: detected ?? .everyDays(interval, onSchedule: medianPhase(Array(days.prefix(phaseReleases)), interval: interval)),
            lateness: min(max(gaps[gaps.count - 1] - interval, 0), interval / 2),
            pastBreaks: zip(history, history.dropFirst()).map { newer, older in older.daysUntil(newer) }
                .filter { $0 > interval * hiatusCycles }
        )
    }

    /// The release in `days`, newest first, that the others land closest to in step with
    /// `interval`, so one early or late release doesn't shift the schedule. Ties go to the newest.
    private static func medianPhase(_ days: [Day], interval: Int) -> Day {
        func offset(_ from: Day, _ to: Day) -> Int {
            let o = floorMod(from.daysUntil(to), interval)
            return min(o, interval - o)
        }
        var phase = days[0]
        var best = Int.max
        for candidate in days {
            let total = days.reduce(0) { $0 + offset(candidate, $1) }
            if total < best { best = total; phase = candidate }
        }
        let onPhase = days.filter { offset(phase, $0) == 0 }.count
        return onPhase * 5 >= days.count * 3 ? phase : days[0]
    }
}
