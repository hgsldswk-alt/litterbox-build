import Foundation

enum RatingAxis: String, Codable, CaseIterable, Identifiable {
    case odor, dust, clump
    var id: String { rawValue }
    var label: String { L.t("rating.\(rawValue)") }
    var low: String { L.t("rating.\(rawValue).low") }
    var high: String { L.t("rating.\(rawValue).high") }
}

struct DailyRating: Codable, Equatable {
    var scores: [RatingAxis: Int] = [:]
    var note = ""
}

struct LitterTrial: Codable, Identifiable, Equatable {
    var id = UUID()
    var boxID: UUID
    var name: String
    var conditions: String
    var start: Date
    var duration = 7
    var days: [Int: DailyRating] = [:]

    func offset(at now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                to: calendar.startOfDay(for: now)).day ?? 0
    }

    mutating func rate(_ axis: RatingAxis, score: Int, day: Int) {
        guard (0..<duration).contains(day), (1...5).contains(score) else { return }
        days[day, default: DailyRating()].scores[axis] = score
    }
}

struct TrialComparison {
    struct Sample {
        let count: Int
        let average: Double?
        init(_ scores: [Int]) {
            count = scores.count
            average = count > 0 ? Double(scores.reduce(0, +)) / Double(count) : nil
        }
    }

    let first: LitterTrial
    let second: LitterTrial
    var span: Int { min(first.duration, second.duration) }
    var sameConditions: Bool {
        first.boxID == second.boxID
            && first.conditions.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(second.conditions.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
    func daysLogged(_ trial: LitterTrial) -> Int {
        trial.days.filter { (0..<span).contains($0.key) && !$0.value.scores.isEmpty }.count
    }
    func sample(_ trial: LitterTrial, axis: RatingAxis) -> Sample {
        Sample((0..<span).compactMap { trial.days[$0]?.scores[axis] })
    }
    func qualifies(_ axis: RatingAxis) -> Bool {
        sameConditions && sample(first, axis: axis).count >= 3 && sample(second, axis: axis).count >= 3
    }
    var canShare: Bool { RatingAxis.allCases.allSatisfy(qualifies) }
    func conclusion(_ axis: RatingAxis) -> String? {
        guard qualifies(axis), let a = sample(first, axis: axis).average,
              let b = sample(second, axis: axis).average else { return nil }
        if abs(a - b) < 0.05 { return L.f("compare.tie", axis.label) }
        return L.f("compare.win.\(axis.rawValue)", a > b ? first.name : second.name)
    }

    static func defaultPair(_ trials: [LitterTrial]) -> Self? {
        let sorted = trials.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start > $1.start }
        var fallback: Self?
        for first in sorted {
            for second in sorted where first.id != second.id && first.boxID == second.boxID {
                let pair = Self(first: first, second: second)
                if pair.canShare { return pair }
                if fallback == nil { fallback = pair }
            }
        }
        return fallback
    }
}
