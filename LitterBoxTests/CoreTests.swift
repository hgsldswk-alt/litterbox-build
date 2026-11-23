import CoreImage
import XCTest

final class CoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testActionsAndBoxesStayIndependentAndUndoRecalculates() throws {
        var home = Household.initial(at: now - 14 * 86_400)
        let box = try XCTUnwrap(home.boxes.first)
        let second = LitterBox(name: "B", createdAt: now - 2 * 86_400)
        home.boxes.append(second)
        let old = try XCTUnwrap(home.log(box: box, kind: .scoop, at: now - 3600, now: now, live: false))
        let wash = try XCTUnwrap(home.log(box: box, kind: .wash, at: now - 10, now: now, live: true))
        let current = try XCTUnwrap(home.log(box: box, kind: .scoop, at: now, now: now, live: true))
        XCTAssertNil(home.log(box: box, kind: .scoop, at: now + 1, now: now + 1, live: true))
        XCTAssertEqual(home.due(box, .scoop), now + 86_400)
        XCTAssertEqual(home.due(box, .wash), wash.at + 14 * 86_400)
        XCTAssertNil(home.due(second, .scoop))
        _ = home.log(box: box, kind: .scoop, at: now - 7200, now: now, live: false)
        XCTAssertEqual(home.latest(box.id, .scoop), current)
        home.revoked.insert(current.id)
        XCTAssertEqual(home.due(box, .scoop), old.at + 86_400)
        XCTAssertEqual(home.events.count, 4)
        XCTAssertFalse(home.writable(second, pro: false))
    }

    func testReminderEnablementPauseQuietHoursAndDaylightSaving() throws {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let beforeDST = try XCTUnwrap(result.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23)))
        let localMidnightSunday = try XCTUnwrap(result.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        var home = Household.initial(at: beforeDST)
        var box = try XCTUnwrap(home.boxes.first)
        home.quiet.enabled = true
        XCTAssertNil(home.notificationDate(box, .scoop, now: beforeDST, calendar: result))
        box.scoop.enabledAt = beforeDST
        box.scoop.enabled = true
        XCTAssertEqual(home.due(box, .scoop), beforeDST + 86_400)
        XCTAssertEqual(result.component(.hour, from: beforeDST + 86_400), 0)
        let delivery = try XCTUnwrap(home.notificationDate(box, .scoop, now: localMidnightSunday, calendar: result))
        XCTAssertEqual(result.component(.hour, from: delivery), 7)
        box.pausedUntil = delivery + 3600
        XCTAssertEqual(home.notificationDate(box, .scoop, now: localMidnightSunday, calendar: result), delivery + 3600)
        box.archived = true
        XCTAssertFalse(home.writable(box, pro: true))
    }

    func testHouseholdRoundTripPreservesLocalRulesAndDeduplicates() throws {
        var remote = Household.initial(at: now - 1000)
        remote.member = .init(name: "Alex")
        let box = try XCTUnwrap(remote.boxes.first)
        let event = try XCTUnwrap(remote.log(box: box, kind: .scoop, at: now - 60, now: now, live: true))
        let code = try FamilyCode.encode(FamilyUpdate(remote, at: now))
        let update = try FamilyCode.decode(code, now: now)
        var receiver = Household.initial(at: now)
        try receiver.merge(receiver.preview(update, now: now), at: now)
        XCTAssertEqual(receiver.id, remote.id)
        XCTAssertEqual(receiver.boxes.map(\.id), [box.id])
        XCTAssertEqual(receiver.effectiveEvents, [event])
        receiver.boxes[0].scoop.hours = 48
        let repeated = try receiver.preview(update, now: now)
        XCTAssertTrue(repeated.newEvents.isEmpty)
        try receiver.merge(repeated, at: now)
        XCTAssertEqual(receiver.boxes[0].scoop.hours, 48)
        XCTAssertEqual(receiver.events.count, 1)

        remote.revoked.insert(event.id)
        let revocation = FamilyUpdate(remote, at: now)
        try receiver.merge(receiver.preview(revocation, now: now), at: now)
        try receiver.merge(receiver.preview(update, now: now), at: now)
        XCTAssertTrue(receiver.effectiveEvents.isEmpty)
        var fresh = Household.initial(at: now)
        try fresh.merge(fresh.preview(revocation, now: now), at: now)
        try fresh.merge(fresh.preview(update, now: now), at: now)
        XCTAssertTrue(fresh.effectiveEvents.isEmpty)
    }

    func testHouseholdWrongGroupAndMalformedInput() throws {
        var local = Household.initial(at: now - 1000)
        let box = try XCTUnwrap(local.boxes.first)
        _ = local.log(box: box, kind: .scoop, at: now, now: now, live: true)
        let update = FamilyUpdate(Household.initial(at: now), at: now)
        let original = local
        let preview = try local.preview(update, now: now)
        XCTAssertTrue(preview.needsSeparateGroup)
        XCTAssertThrowsError(try local.merge(preview, at: now))
        XCTAssertEqual(local, original)
        let code = try FamilyCode.encode(update)
        let altered = "LBT1:" + (code.dropFirst(5).first == "0" ? "1" : "0") + String(code.dropFirst(6))
        XCTAssertThrowsError(try FamilyCode.decode(altered, now: now))
        XCTAssertThrowsError(try FamilyCode.decode("LBT1:00000000.", now: now))
        let missing = Data("{\"version\":1}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FamilyUpdate.self, from: missing))
        XCTAssertThrowsError(try FamilyCode.decode(String(repeating: "a", count: FamilyCode.fileLimit + 1), now: now))
        XCTAssertThrowsError(try FamilyCode.decode(code, now: now - 86_400))
    }

    func testTrialUsesSameSpanAndRequiresThreeSamplesPerAxis() {
        let id = UUID()
        var a = LitterTrial(boxID: id, name: "Clay", conditions: "Hall", start: now, duration: 7)
        var b = LitterTrial(boxID: id, name: "Paper", conditions: "hall", start: now - 10 * 86_400, duration: 5)
        a.rate(.odor, score: 1, day: 0)
        a.rate(.odor, score: 4, day: 0)
        a.rate(.odor, score: 5, day: 6)
        XCTAssertEqual(a.days[0]?.scores[.odor], 4)
        var result = TrialComparison(first: a, second: b)
        XCTAssertEqual(result.span, 5)
        XCTAssertEqual(result.sample(a, axis: .odor).count, 1)
        XCTAssertNil(result.sample(b, axis: .dust).average)
        XCTAssertFalse(result.canShare)
        for day in 0..<3 {
            for axis in RatingAxis.allCases {
                a.rate(axis, score: 4, day: day)
                b.rate(axis, score: 2, day: day)
            }
        }
        result = TrialComparison(first: a, second: b)
        XCTAssertTrue(result.canShare)
        XCTAssertEqual(result.sample(a, axis: .odor).average, 4)
        b.conditions = "Different"
        XCTAssertFalse(TrialComparison(first: a, second: b).canShare)
        b.conditions = a.conditions
        b.boxID = UUID()
        XCTAssertFalse(TrialComparison(first: a, second: b).canShare)
    }

    func testEntitlementExpiryRollbackReloadReceiptAndPurchase() throws {
        var value = Entitlement(firstOpen: now - 60 * 86_400)
        value.observe(now, free: false)
        XCTAssertEqual(value.trialStart, now)
        XCTAssertTrue(value.hasPro(at: now + 30 * 86_400 - 1, free: false))
        XCTAssertFalse(value.hasPro(at: now + 30 * 86_400, free: false))
        value.applyTrialReceipt(now + 86_400)
        XCTAssertEqual(value.trialStart, now)
        value.observe(now + 31 * 86_400, free: false)
        let bytes = try JSONEncoder().encode(value)
        var reopened = try JSONDecoder().decode(Entitlement.self, from: bytes)
        XCTAssertEqual(reopened.proStartedAt, now)
        XCTAssertFalse(reopened.hasPro(at: now + 1, free: false))
        reopened.purchasedPro = true
        XCTAssertTrue(reopened.hasPro(at: now + 1, free: false))
        reopened.purchasedPro = false
        reopened.applyTrialReceipt(now - 86_400)
        XCTAssertEqual(reopened.trialStart, now - 86_400)
    }

    func testMilestoneUsesHouseholdDaysAndPauseBreaksStreak() throws {
        var home = Household.initial(at: now - 30 * 86_400)
        home.timeZone = "UTC"
        let today = home.calendar.startOfDay(for: now)
        let loggingTime = today + 3600
        home.boxes[0].createdAt = loggingTime - 29 * 86_400 - 60
        let box = try XCTUnwrap(home.boxes.first)
        for offset in (0..<30).reversed() {
            let date = loggingTime - Double(offset) * 86_400
            _ = home.log(box: box, kind: .scoop, at: date, now: date, live: true)
        }
        XCTAssertEqual(home.milestoneStreak(at: loggingTime + 60, pro: true), 30)
        home.boxes[0].pauses = [DateInterval(start: loggingTime - 2 * 86_400, duration: 1800)]
        XCTAssertEqual(home.milestoneStreak(at: loggingTime + 60, pro: true), 2)
    }

    func testDownloadQRCanBeReadByCoreImage() throws {
        for id in ["", "1234567890"] {
            let url = ShareQR.destination(storeID: id)
            let image = try XCTUnwrap(ShareQR.image(url: url))
            let withQuietZone = image.composited(over: CIImage(color: .white))
                .cropped(to: image.extent.insetBy(dx: -36, dy: -36))
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                                   options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let messages = detector.features(in: withQuietZone).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertTrue(messages.contains(url.absoluteString))
        }
    }
}
