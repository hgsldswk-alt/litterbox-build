import Foundation

enum Demo {
    static func data(at now: Date) -> LocalData {
        var home = Household()
        home.member = HouseholdMember(name: L.t("demo.maya"))
        let alex = HouseholdMember(name: L.t("demo.alex"))
        let start = now.addingTimeInterval(-55 * 86_400)
        let hall = LitterBox(name: L.t("demo.hall"), cats: [.init(name: L.t("demo.miso")), .init(name: L.t("demo.nori"))],
                             createdAt: start, scoop: .init(hours: 24, enabled: true, enabledAt: start),
                             wash: .init(hours: 336, enabled: true, enabledAt: start))
        let laundry = LitterBox(name: L.t("demo.laundry"), cats: [.init(name: L.t("demo.nori"))], createdAt: start)
        home.boxes = [hall, laundry]
        home.freeBoxID = hall.id
        home.lockBoxID = hall.id
        home.events = [
            .init(boxID: hall.id, kind: .scoop, at: now - 27 * 3600, member: alex),
            .init(boxID: hall.id, kind: .wash, at: now - 9 * 86_400, member: home.member),
            .init(boxID: laundry.id, kind: .scoop, at: now - 2 * 3600, member: home.member),
            .init(boxID: laundry.id, kind: .wash, at: now - 3 * 86_400, member: alex)
        ]
        let today = home.calendar.startOfDay(for: now)
        func prior(_ days: Int) -> Date { home.calendar.date(byAdding: .day, value: -days, to: today) ?? today }
        var clay = LitterTrial(boxID: hall.id, name: L.t("demo.clay"), conditions: "", start: prior(3))
        var paper = LitterTrial(boxID: hall.id, name: L.t("demo.paper"), conditions: "", start: prior(11))
        for day in 0..<7 {
            for (axis, scores) in [(RatingAxis.odor, [3, 4]), (.dust, [5, 3]), (.clump, [2, 5])] {
                if day < 4 { clay.rate(axis, score: scores[1], day: day) }
                paper.rate(axis, score: scores[0], day: day)
            }
        }
        home.trials = [clay, paper]
        home.importNote = ImportNote(from: alex.name, at: now - 3 * 3600, events: [home.events[0], home.events[3]])
        return LocalData(home: home)
    }

    static func update(from home: Household, now: Date) -> FamilyUpdate {
        var remote = home
        remote.member = HouseholdMember(name: L.t("demo.alex"))
        if let box = home.boxes.last {
            remote.events.append(CareEvent(boxID: box.id, kind: .scoop, at: now - 600, member: remote.member))
        }
        return FamilyUpdate(remote, at: now)
    }
}
