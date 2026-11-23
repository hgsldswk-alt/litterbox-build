import Foundation

enum CareKind: String, Codable, CaseIterable, Identifiable {
    case scoop, wash
    var id: String { rawValue }
    var label: String { L.t("care.\(rawValue)") }
    var action: String { L.t("log.\(rawValue)") }
    var presets: [Int] { self == .scoop ? [12, 24, 48] : [168, 336, 720] }
    var defaultHours: Int { self == .scoop ? 24 : 336 }
}

struct ReminderRule: Codable, Equatable {
    var hours: Int
    var enabled = false
    var enabledAt: Date?
}

struct CatLabel: Codable, Equatable { var name: String }
struct HouseholdMember: Codable, Equatable { var id = UUID(); var name: String }

struct LitterBox: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var cats: [CatLabel] = []
    var createdAt = Date()
    var archived = false
    var archivedAt: Date? = nil
    var isStarter: Bool? = nil
    var scoop = ReminderRule(hours: 24)
    var wash = ReminderRule(hours: 336)
    var pausedUntil: Date?
    var pauses: [DateInterval]? = nil

    subscript(kind: CareKind) -> ReminderRule {
        get { kind == .scoop ? scoop : wash }
        set { if kind == .scoop { scoop = newValue } else { wash = newValue } }
    }
}

struct CareEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var boxID: UUID
    var kind: CareKind
    var at: Date
    var member: HouseholdMember
    var onTime: Bool?
    var intervalHours: Int? = nil
}

struct QuietHours: Codable, Equatable {
    var enabled = false
    var startMinute = 22 * 60
    var endMinute = 7 * 60

    func adjusted(_ date: Date, calendar: Calendar) -> Date {
        guard enabled, startMinute != endMinute else { return date }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let isQuiet = startMinute < endMinute
            ? minute >= startMinute && minute < endMinute
            : minute >= startMinute || minute < endMinute
        guard isQuiet else { return date }
        return calendar.nextDate(after: date,
            matching: DateComponents(hour: endMinute / 60, minute: endMinute % 60),
            matchingPolicy: .nextTime) ?? date
    }
}

struct ImportNote: Codable, Equatable {
    var from: String
    var at: Date
    var events: [CareEvent]
}

struct Household: Codable, Equatable {
    var id = UUID()
    var member = HouseholdMember(name: "")
    var members: [HouseholdMember] = []
    var timeZone = TimeZone.current.identifier
    var boxes: [LitterBox] = []
    var events: [CareEvent] = []
    var revoked: Set<UUID> = []
    var trials: [LitterTrial] = []
    var freeBoxID: UUID?
    var lockBoxID: UUID?
    var showBoxName = true
    var quiet = QuietHours()
    var importNote: ImportNote?
    var milestoneAt: Date?
    var milestonePresented: Bool? = nil

    static func initial(at now: Date = Date()) -> Self {
        var home = Self()
        let box = LitterBox(name: L.t("box.default"), createdAt: now, isStarter: true)
        home.boxes = [box]
        home.freeBoxID = box.id
        return home
    }

    var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: timeZone) ?? .current
        return result
    }

    var freeBox: UUID? {
        if let freeBoxID, boxes.contains(where: { $0.id == freeBoxID && !$0.archived }) { return freeBoxID }
        return boxes.filter { !$0.archived }.min { $0.createdAt < $1.createdAt }?.id
    }

    var effectiveEvents: [CareEvent] { events.filter { !revoked.contains($0.id) } }
    var isEmpty: Bool {
        events.isEmpty && trials.isEmpty && boxes.count == 1
            && boxes[0].cats.isEmpty && boxes[0].isStarter == true
            && CareKind.allCases.allSatisfy {
                !boxes[0][$0].enabled && boxes[0][$0].hours == $0.defaultHours
            }
            && !boxes[0].archived && boxes[0].pausedUntil == nil && !quiet.enabled && importNote == nil
    }

    func writable(_ box: LitterBox, pro: Bool) -> Bool {
        !box.archived && (pro || box.id == freeBox)
    }

    func latest(_ id: UUID, _ kind: CareKind) -> CareEvent? {
        effectiveEvents.filter { $0.boxID == id && $0.kind == kind }.max { lhs, rhs in
            lhs.at == rhs.at ? lhs.id.uuidString < rhs.id.uuidString : lhs.at < rhs.at
        }
    }

    func due(_ box: LitterBox, _ kind: CareKind) -> Date? {
        let rule = box[kind]
        let anchor = latest(box.id, kind)?.at ?? (rule.enabled ? rule.enabledAt : nil)
        return anchor?.addingTimeInterval(Double(rule.hours) * 3600)
    }

    func urgency(_ box: LitterBox) -> Date {
        CareKind.allCases.compactMap { due(box, $0) }.min() ?? .distantFuture
    }

    func notificationDate(_ box: LitterBox, _ kind: CareKind, now: Date, calendar: Calendar) -> Date? {
        guard box[kind].enabled, let due = due(box, kind) else { return nil }
        let dispatch = quiet.adjusted(max(due, box.pausedUntil ?? due), calendar: calendar)
        return dispatch > now ? dispatch : nil
    }

    @discardableResult
    mutating func log(box: LitterBox, kind: CareKind, at: Date, now: Date, live: Bool, by author: HouseholdMember? = nil) -> CareEvent? {
        let previous = latest(box.id, kind)
        if live, let previous, abs(at.timeIntervalSince(previous.at)) < 3 { return nil }
        let onTime = effectiveEvents.filter { $0.boxID == box.id && $0.kind == kind && $0.at < at }
            .max { $0.at < $1.at }.map { at.timeIntervalSince($0.at) <= Double(box[kind].hours) * 3600 }
            ?? box[kind].enabledAt.map { at.timeIntervalSince($0) <= Double(box[kind].hours) * 3600 } ?? true
        let event = CareEvent(boxID: box.id, kind: kind, at: min(now, at), member: author ?? member,
                              onTime: kind == .scoop ? onTime : nil,
                              intervalHours: kind == .scoop ? box.scoop.hours : nil)
        events.append(event)
        return event
    }

    func milestoneStreak(at now: Date, pro: Bool) -> Int {
        let active = boxes.filter { pro || $0.id == freeBox }
        var eventsByBox: [UUID: [CareEvent]] = [:]
        for event in effectiveEvents where event.kind == .scoop { eventsByBox[event.boxID, default: []].append(event) }
        let today = calendar.startOfDay(for: now)
        var streak = 0
        for offset in 0...30 {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { break }
            let present = active.filter { $0.createdAt < end && ($0.archivedAt.map { $0 > start } ?? !$0.archived) }
            let relevant = present.map { (box: $0, all: eventsByBox[$0.id] ?? []) }
            let dayEvents = relevant.flatMap { $0.all.filter { $0.at >= start && $0.at < end } }
            if offset == 0 && dayEvents.isEmpty { return 0 }
            guard !dayEvents.isEmpty else { break }
            let valid = relevant.allSatisfy { item in
                let day = DateInterval(start: start, end: min(end, now))
                if (item.box.pauses ?? []).contains(where: { $0.start < day.end && $0.end > day.start }) { return false }
                let logs = item.all.filter { $0.at >= start && $0.at < end }.sorted { $0.at < $1.at }
                let previous = item.all.filter { $0.at < start }.max { $0.at < $1.at }
                let hours = logs.first?.intervalHours ?? previous?.intervalHours ?? item.box.scoop.hours
                if hours > 24 && logs.isEmpty { return false }
                var anchor = previous?.at ?? item.box.createdAt
                var window = hours
                for log in logs {
                    window = log.intervalHours ?? window
                    if log.at.timeIntervalSince(anchor) > Double(window) * 3600 { return false }
                    anchor = log.at
                }
                let deadline = anchor.addingTimeInterval(Double(window) * 3600)
                return min(end, now, item.box.archivedAt ?? .distantFuture) <= deadline
            }
            guard valid else { break }
            streak += 1
            if streak >= 30 { break }
        }
        return streak
    }
}

enum Day {
    static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

struct LocalData: Codable, Equatable {
    var version = 1
    var home: Household
    var otherHomes: [Household] = []
    var reviewedVersion: String?
    var reviewDays: Set<String> = []
}
