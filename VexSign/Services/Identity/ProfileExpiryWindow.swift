import Foundation

/// Rolling 24-hour periods, independent of time zone and daylight-saving changes.
struct ProfileExpiryWindow {
    enum Milestone: Equatable { case expired, finalDay, days(Int), weekOrMore }

    let fraction: Double
    let milestone: Milestone

    init(expiration: Date, now: Date) {
        let days = expiration.timeIntervalSince(now) / 86_400
        fraction = min(max(days / 7, 0), 1)
        if days <= 0 { milestone = .expired }
        else if days < 1 { milestone = .finalDay }
        else if days >= 7 { milestone = .weekOrMore }
        else { milestone = .days(Int(days)) }
    }
}
