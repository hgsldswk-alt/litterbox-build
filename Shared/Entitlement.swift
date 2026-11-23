import Foundation

struct Entitlement: Codable, Equatable {
    var firstOpen = Date()
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false
    var lastSeen: Date?
    private static let duration: TimeInterval = 30 * 86_400

    var trialStart: Date {
        let start = proStartedAt ?? firstOpen
        return trialClaimedAt.map { min(start, $0) } ?? start
    }

    var trialEnd: Date { trialStart.addingTimeInterval(Self.duration) }
    func effectiveTime(_ now: Date) -> Date { max(now, lastSeen ?? now) }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || effectiveTime(now) < trialEnd
    }

    func daysLeft(at now: Date) -> Int {
        Int(ceil(max(0, trialEnd.timeIntervalSince(effectiveTime(now))) / 86_400))
    }

    mutating func observe(_ now: Date, free: Bool = Launch.isFree) {
        if !free && proStartedAt == nil { proStartedAt = now }
        lastSeen = effectiveTime(now)
    }

    mutating func applyTrialReceipt(_ date: Date) {
        trialClaimedAt = min(trialClaimedAt ?? date, date)
    }
}
