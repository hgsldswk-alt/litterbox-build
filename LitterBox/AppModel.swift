import Foundation
import StoreKit
import SwiftUI
import UIKit
import UserNotifications
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    enum Tab: String, CaseIterable { case boxes, trials, family, history }

    @Published private(set) var data: LocalData?
    @Published private(set) var entitlement: Entitlement?
    @Published var tab: Tab = .boxes
    @Published var selectedBox: UUID?
    @Published var feedback: CareEvent?
    @Published var error: String?
    @Published var reviewSignal = 0
    @Published var reviewOpportunity = 0
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published var now = Date()
    @Published var pendingWrites = 0
    @Published var opening = false
    @Published var shareRequested = false
    @Published var importPreview: FamilyPreview?
    private let repository = LocalStore()
    private let secure = SecureEntitlement()
    private let notifications = CareNotifications()
    private var pending: Task<Void, Never>?
    private var sideEffects: Task<Void, Never>?
    private var undoTimer: Task<Void, Never>?
    private var expiryTimer: Task<Void, Never>?
    private var lastCheckpoint = Date.distantPast
    private let uptime = ContinuousClock()
    private var entitlementAnchor: (instant: ContinuousClock.Instant, date: Date)?

    var home: Household? { data?.home }
    var accessNow: Date {
        guard let entitlementAnchor else { return now }
        let duration = entitlementAnchor.instant.duration(to: uptime.now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        return max(now, entitlementAnchor.date.addingTimeInterval(seconds))
    }
    var pro: Bool { entitlement?.hasPro(at: accessNow) ?? false }
    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    var trialEnd: Date? {
        guard !Launch.isFree, let entitlement, !entitlement.purchasedPro else { return nil }
        return entitlement.trialEnd
    }
    var notificationDenied: Bool { notificationStatus == .denied }

    func open() async {
        guard data == nil, !opening else { return }
        opening = true
        defer { opening = false }
        let timestamp = Date()
        do {
            async let disk = repository.open(at: timestamp)
            async let rights = secure.open(at: timestamp)
            let (loaded, access) = try await (disk, rights)
            now = timestamp
            entitlement = access
            entitlementAnchor = (uptime.now, access.effectiveTime(timestamp))
            data = loaded
            scheduleExpiry()
            publishSideEffects()
            notificationStatus = await notifications.authorization()
        } catch {
            self.error = "error.open"
        }
    }

    func updateTime() {
        let before = pro
        now = Date()
        if before != pro { publishSideEffects() }
    }

    func activate(force: Bool = false) async {
        guard data != nil else { return }
        updateTime()
        let status = await notifications.authorization()
        let changed = notificationStatus != status
        notificationStatus = status
        if force || changed { publishSideEffects() }
        if accessNow.timeIntervalSince(lastCheckpoint) >= 60 || force {
            await refreshEntitlement()
        }
    }

    func watchPurchases() async {
        guard !Launch.uiTesting && !Launch.isFree else { return }
        await syncPurchases()
        for await result in Transaction.updates {
            if Task.isCancelled { break }
            guard case .verified(let transaction) = result else { continue }
            await apply(transaction)
        }
    }

    func syncPurchases(restoring: Bool = false) async {
        guard !Launch.uiTesting && !Launch.isFree else { return }
        let verified = await Purchases.entitlements()
        await refreshEntitlement(purchased: verified.purchased ? true : (restoring ? false : nil), trial: verified.trial)
    }

    func apply(_ transaction: Transaction) async {
        switch transaction.productID {
        case Purchases.proID:
            if await refreshEntitlement(purchased: transaction.revocationDate == nil) { await transaction.finish() }
        case Purchases.trialID:
            if await refreshEntitlement(trial: transaction.revocationDate == nil ? transaction.originalPurchaseDate : nil) {
                await transaction.finish()
            }
        default: break
        }
    }

    @discardableResult
    private func refreshEntitlement(purchased: Bool? = nil, trial: Date? = nil) async -> Bool {
        let timestamp = max(Date(), accessNow)
        do {
            let old = pro
            let oldExpiry = trialEnd
            let rights = try await secure.reconcile(at: timestamp, purchased: purchased, trial: trial)
            entitlement = rights
            now = Date()
            let effective = rights.effectiveTime(timestamp)
            entitlementAnchor = (uptime.now, effective)
            lastCheckpoint = effective
            scheduleExpiry()
            if old != pro || oldExpiry != trialEnd { publishSideEffects() }
            return true
        } catch {
            if purchased != nil || trial != nil { self.error = "error.save" }
            return false
        }
    }

    private func scheduleExpiry() {
        expiryTimer?.cancel()
        guard let end = trialEnd, let entitlement, pro else { return }
        let seconds = end.timeIntervalSince(entitlement.effectiveTime(accessNow))
        expiryTimer = Task {
            do { try await Task.sleep(for: .seconds(max(0, seconds))) } catch { return }
            updateTime()
            await activate(force: true)
        }
    }

    func askNotifications() {
        Task {
            do {
                notificationStatus = try await notifications.request()
                publishSideEffects()
            } catch {
                self.error = "error.notifications"
            }
        }
    }

    func edit(_ change: @escaping (inout Household, Date, Bool) throws -> Void, completed: (() -> Void)? = nil) {
        enqueue({ next, date, pro in try change(&next.home, date, pro); return nil }, completed: completed)
    }

    func observeReview(eligible: Bool, request: @escaping () -> Void) {
        guard eligible, feedback == nil, pendingWrites == 0, error == nil,
              let data, data.reviewDays.count >= 3, data.reviewedVersion != version else { return }
        let version = version
        enqueue { next, _, _ in next.reviewedVersion = version; return nil } completed: {
            if Launch.uiTesting { self.reviewSignal += 1 }
            else { request() }
        }
    }

    func log(_ boxID: UUID, _ kind: CareKind, date: Date? = nil, eventID: UUID? = nil, completed: (() -> Void)? = nil) {
        enqueue { next, now, pro in
            guard let box = next.home.boxes.first(where: { $0.id == boxID }), next.home.writable(box, pro: pro) else {
                throw EditingError.unavailable
            }
            var author: HouseholdMember?
            if let eventID {
                guard let original = next.home.effectiveEvents.first(where: { $0.id == eventID }),
                      let source = next.home.boxes.first(where: { $0.id == original.boxID }),
                      next.home.writable(source, pro: pro) else { throw EditingError.unavailable }
                author = original.member
                next.home.revoked.insert(eventID)
            }
            guard let entry = next.home.log(box: box, kind: kind, at: date ?? now, now: now, live: date == nil, by: author) else {
                return nil
            }
            if date == nil && kind == .scoop {
                if Launch.has("-review") {
                    next.reviewDays.formUnion(["test-day-1", "test-day-2"])
                }
                next.reviewDays.insert(Day.key(now, calendar: next.home.calendar))
            }
            return date == nil ? entry : nil
        } completed: { completed?() }
    }

    func undo(_ event: CareEvent) {
        edit { home, _, pro in
            guard let box = home.boxes.first(where: { $0.id == event.boxID }),
                  home.writable(box, pro: pro) else { throw EditingError.unavailable }
            home.revoked.insert(event.id)
        }
    }

    func preview(_ text: String) async {
        importPreview = nil
        do {
            let timestamp = Date()
            let update = try await Task.detached(priority: .userInitiated) {
                try FamilyCode.decode(text, now: timestamp)
            }.value
            guard let home else { return }
            importPreview = try home.preview(update, now: timestamp)
        } catch {
            self.error = transferError(error)
        }
    }

    func merge(_ preview: FamilyPreview, separate: Bool = false) {
        enqueue { next, timestamp, pro in
            guard pro else { throw EditingError.unavailable }
            guard next.home.id == preview.groupID else { throw TransferError.stalePreview }
            if separate {
                if let index = next.otherHomes.firstIndex(where: { $0.id == preview.update.householdID }) {
                    let existing = next.otherHomes.remove(at: index)
                    next.otherHomes.append(next.home)
                    next.home = existing
                } else {
                    let member = next.home.member
                    next.otherHomes.append(next.home)
                    next.home = Household.initial(at: timestamp)
                    next.home.member = member
                }
                let target = try next.home.preview(preview.update, now: timestamp)
                try next.home.merge(target, at: timestamp)
            } else {
                try next.home.merge(preview, at: timestamp)
            }
            return nil
        } completed: { self.importPreview = nil }
    }

    func switchHousehold(_ id: UUID) {
        enqueue { next, _, _ in
            guard let index = next.otherHomes.firstIndex(where: { $0.id == id }) else { return nil }
            let other = next.otherHomes.remove(at: index)
            next.otherHomes.append(next.home)
            next.home = other
            return nil
        } completed: { self.importPreview = nil }
    }

    func transferError(_ error: Error) -> String {
        switch error as? TransferError {
        case .tooLarge: return "error.tooLarge"
        case .wrongHousehold, .stalePreview: return "error.group"
        default: return "error.code"
        }
    }

    private func enqueue(_ change: @escaping (inout LocalData, Date, Bool) throws -> CareEvent?,
                         completed: (() -> Void)? = nil) {
        let before = pending
        pendingWrites += 1
        pending = Task {
            await before?.value
            defer { pendingWrites -= 1 }
            guard var next = data else { return }
            updateTime()
            do {
                let event = try change(&next, now, pro)
                if next != data {
                    if next.home.milestoneAt == nil {
                        let home = next.home
                        let timestamp = now
                        let access = pro
                        let streak = await Task.detached(priority: .userInitiated) {
                            home.milestoneStreak(at: timestamp, pro: access)
                        }.value
                        if streak >= 30 { next.home.milestoneAt = timestamp }
                    }
                    try await repository.save(next)
                    data = next
                    if let event { didLog(event) }
                    if let feedback, !next.home.effectiveEvents.contains(where: { $0.id == feedback.id }) {
                        undoTimer?.cancel()
                        self.feedback = nil
                    }
                    publishSideEffects()
                }
                completed?()
            } catch {
                if let error = error as? TransferError { self.error = transferError(error) }
                else { self.error = error is EditingError ? "error.locked" : "error.save" }
            }
        }
    }

    private func didLog(_ event: CareEvent) {
        undoTimer?.cancel()
        feedback = event
        if !Launch.uiTesting { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        undoTimer = Task {
            do { try await Task.sleep(for: .seconds(Launch.has("-review") ? 2 : 8)) } catch { return }
            feedback = nil
            if event.kind == .scoop { reviewOpportunity += 1 }
        }
    }

    private func publishSideEffects() {
        guard let home, !Launch.uiTesting else { return }
        let timestamp = now
        let access = pro
        let expires = trialEnd
        let before = sideEffects
        sideEffects = Task {
            await before?.value
            do {
                try await repository.widget(home: home, pro: access, expires: expires, at: timestamp)
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
            }
        }
        let schedule = CareNotifications.Schedule(home: home, pro: access, now: timestamp, expires: expires)
        Task { await notifications.update(schedule) }
    }
}

enum EditingError: Error { case unavailable }
