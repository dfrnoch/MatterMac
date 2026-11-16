import Foundation
import Testing
@testable import MatterMacUI

@MainActor
@Suite("Send Later presets")
struct SendLaterOptionsTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        return calendar
    }

    func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test func wednesdayOffersAnHourTomorrowAndMonday() {
        let options = SendLaterOptions.presets(now: date(18, 15), calendar: calendar)
        #expect(options.map(\.date) == [date(18, 16), date(19, 9), date(23, 9)])
    }

    @Test func sundayDropsMondayBecauseItIsTomorrow() {
        let options = SendLaterOptions.presets(now: date(22, 20), calendar: calendar)
        #expect(options.map(\.date) == [date(22, 21), date(23, 9)])
    }

    @Test func mondayMorningOffersNextMondayNotToday() {
        let options = SendLaterOptions.presets(now: date(23, 7), calendar: calendar)
        #expect(options.last?.date == date(30, 9))
    }
}
