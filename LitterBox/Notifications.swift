import Foundation
import UserNotifications

actor CareNotifications {
    struct Schedule {
        let home: Household
        let pro: Bool
        let now: Date
        let expires: Date?
    }

    private let center = UNUserNotificationCenter.current()
    private var next: Schedule?
    private var running = false
    private let prefix = "lbt.care."

    func authorization() async -> UNAuthorizationStatus {
        if Launch.uiTesting { return Launch.has("-denied") ? .denied : .authorized }
        return await center.notificationSettings().authorizationStatus
    }

    func request() async throws -> UNAuthorizationStatus {
        if Launch.uiTesting { return await authorization() }
        if await authorization() == .notDetermined {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        return await authorization()
    }

    func update(_ schedule: Schedule) async {
        guard !Launch.uiTesting else { return }
        next = schedule
        guard !running else { return }
        running = true
        while let current = next {
            next = nil
            await rebuild(current)
        }
        running = false
    }

    private func rebuild(_ schedule: Schedule) async {
        let requests = await center.pendingNotificationRequests()
        let own = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
        let authorization = await authorization()
        guard [.authorized, .provisional, .ephemeral].contains(authorization) else {
            center.removePendingNotificationRequests(withIdentifiers: own)
            return
        }
        let home = schedule.home
        let tasks = home.boxes.filter { home.writable($0, pro: schedule.pro) }.flatMap { box in
            CareKind.allCases.compactMap { kind -> (LitterBox, CareKind, Date)? in
                guard let date = home.notificationDate(box, kind, now: schedule.now, calendar: .autoupdatingCurrent),
                      box.id == home.freeBox || schedule.expires.map({ date < $0 }) ?? true else { return nil }
                return (box, kind, date)
            }
        }.sorted { $0.2 < $1.2 }
        let limit = max(0, 64 - (requests.count - own.count))
        let plan = tasks.prefix(limit).map { (box, kind, date) in
            (prefix + box.id.uuidString + "." + kind.rawValue, box, kind, date)
        }
        let kept = Set(plan.map { $0.0 })
        center.removePendingNotificationRequests(withIdentifiers: own.filter { !kept.contains($0) })
        for (id, box, kind, date) in plan {
            if next != nil { return }
            let content = UNMutableNotificationContent()
            content.title = L.f("notification.title", box.name, kind.label)
            content.body = L.t(kind == .scoop ? "notification.scoop" : "notification.wash")
            content.sound = .default
            content.userInfo = ["boxID": box.id.uuidString]
            let seconds = date.timeIntervalSinceNow
            guard seconds > 0 else { continue }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}
