import Foundation
import MatterMacModels

/// Preset times offered by Send Later, like the official client: in an hour, tomorrow
/// morning and next Monday morning (dropped when it equals tomorrow).
enum SendLaterOptions {
    static let morningHour = 9

    struct Option: Equatable {
        let title: String
        let date: Date
    }

    static func presets(now: Date, calendar: Calendar = .current) -> [Option] {
        var options = [Option(title: String(localized: "In 1 Hour"), date: now.addingTimeInterval(3_600))]
        let startOfToday = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let tomorrowMorning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: tomorrow)
        else { return options }
        let time = TimelineStrings.time(MattermostTimestamp(date: tomorrowMorning))
        options.append(Option(title: String(localized: "Tomorrow at \(time)"), date: tomorrowMorning))
        let monday = calendar.nextDate(after: tomorrow, matching: DateComponents(hour: morningHour, minute: 0, weekday: 2),
                                       matchingPolicy: .nextTime)
        if let monday, !calendar.isDate(monday, inSameDayAs: tomorrowMorning) {
            options.append(Option(title: String(localized: "Monday at \(time)"), date: monday))
        }
        return options
    }

    /// "Today 15:00", "Tomorrow 09:00" or "Mon 3 Nov 09:00".
    static func describe(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = TimelineStrings.time(MattermostTimestamp(date: date))
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today \(time)") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "Tomorrow \(time)")
        }
        return dayFormatter.string(from: date) + " " + time
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return formatter
    }()
}
