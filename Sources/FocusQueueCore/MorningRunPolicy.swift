import Foundation

public enum MorningRunPolicy {
    public static func isDue(
        now: Date,
        lastSuccessfulAt: Date?,
        hour: Int = 8,
        calendar: Calendar = .current
    ) -> Bool {
        guard let scheduled = calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: now
        ), now >= scheduled else {
            return false
        }
        guard let lastSuccessfulAt else { return true }
        return lastSuccessfulAt < scheduled
    }
}
