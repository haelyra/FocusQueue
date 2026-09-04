import Foundation

public enum MorningRunDisposition: Equatable, Sendable {
    case notDue
    case runAutomatically
    case requestApproval
}

public enum MorningRunPolicy {
    public static func isDue(
        now: Date,
        lastSuccessfulAt: Date?,
        hour: Int = 8,
        calendar: Calendar = .current
    ) -> Bool {
        disposition(
            now: now,
            lastSuccessfulAt: lastSuccessfulAt,
            hour: hour,
            minute: 0,
            automaticGraceMinutes: .max,
            calendar: calendar
        ) != .notDue
    }

    public static func disposition(
        now: Date,
        lastSuccessfulAt: Date?,
        hour: Int,
        minute: Int,
        automaticGraceMinutes: Int = 15,
        availabilityResumedAt: Date? = nil,
        calendar: Calendar = .current
    ) -> MorningRunDisposition {
        guard let scheduled = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: now
        ), now >= scheduled else {
            return .notDue
        }
        if let lastSuccessfulAt, calendar.isDate(lastSuccessfulAt, inSameDayAs: scheduled) {
            return .notDue
        }
        if let availabilityResumedAt, availabilityResumedAt > scheduled {
            return .requestApproval
        }
        let grace: TimeInterval
        if automaticGraceMinutes == .max {
            grace = .greatestFiniteMagnitude
        } else {
            grace = TimeInterval(max(0, automaticGraceMinutes) * 60)
        }
        return now.timeIntervalSince(scheduled) <= grace ? .runAutomatically : .requestApproval
    }
}
