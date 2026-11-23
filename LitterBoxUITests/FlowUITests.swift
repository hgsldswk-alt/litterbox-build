import XCTest

final class FlowUITests: XCTestCase {
    private let session = UUID().uuidString
    private let scenes = ["01-home", "02-log", "03-reminders", "04-compare", "05-family"]
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 900
    }

    private func start(_ flags: [String] = [], language: String = "en", reset: Bool = true) {
        app?.terminate()
        app = XCUIApplication()
        let locales = ["en": "en_US", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW"]
        app.launchArguments = ["-ui-testing", "-paid-mode", "-AppleLanguages", "(\(language))",
                               "-AppleLocale", locales[language] ?? "en_US"] + (reset ? ["-reset"] : []) + flags
        app.launchEnvironment["LBT_TEST_SESSION"] = session
        app.launch()
        XCTAssertTrue(button("tab.boxes").waitForExistence(timeout: 18))
    }

    private func button(_ id: String) -> XCUIElement {
        app.buttons.matching(identifier: id).firstMatch
    }

    private func tap(_ id: String, scroll: Bool = false) {
        let element = button(id)
        if scroll {
            _ = element.waitForExistence(timeout: 3)
            for _ in 0..<5 {
                if element.exists && element.isHittable { break }
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 8), id)
        XCTAssertTrue(element.isHittable, id)
        element.tap()
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testFirstLaunchLogsOnceUndoAndRetainOnReopen() {
        start()
        let emptyTimer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "No log yet")).firstMatch
        XCTAssertTrue(emptyTimer.waitForExistence(timeout: 5))
        tap("log.scoop.0")
        XCTAssertTrue(app.staticTexts["log.feedback"].waitForExistence(timeout: 5))
        tap("log.undo")
        XCTAssertTrue(app.staticTexts["log.feedback"].waitForNonExistence(timeout: 5))
        tap("log.wash.0")
        XCTAssertTrue(app.staticTexts["log.feedback"].waitForExistence(timeout: 5))
        start(reset: false)
        tap("tab.history")
        XCTAssertTrue(app.staticTexts["Litter box · Deep clean"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.staticTexts["Litter box · Scoop"].exists)
    }

    func testDeniedNotificationsStillAllowLogPauseAndPastEntry() {
        start(["-denied"])
        XCTAssertTrue(app.staticTexts["Notifications are off. Due times are still shown here."].waitForExistence(timeout: 6))
        tap("box.reminders.0", scroll: true)
        tap("reminders.scoop.12")
        tap("reminders.pause", scroll: true)
        let tomorrow = app.buttons["Tomorrow"].firstMatch
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 5))
        tomorrow.tap()
        XCTAssertTrue(button("reminders.resume").waitForExistence(timeout: 5))
        tap("sheet.done")
        tap("tab.history")
        tap("history.add")
        tap("past.save")
        XCTAssertTrue(app.staticTexts["Litter box · Scoop"].waitForExistence(timeout: 8))
    }

    func testCreateTrialAndSaveEachRatingImmediately() {
        start()
        tap("tab.trials")
        tap("trial.new")
        let field = app.textFields["trial.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        field.tap()
        field.typeText("Corn litter")
        tap("trial.start", scroll: true)
        XCTAssertTrue(app.staticTexts["Corn litter"].waitForExistence(timeout: 8))
        tap("rating.odor.4", scroll: true)
        tap("rating.dust.3", scroll: true)
        tap("rating.clump.5", scroll: true)
        XCTAssertTrue(app.staticTexts["trial.saved"].waitForExistence(timeout: 8))
        tap("tab.boxes")
        tap("tab.trials")
        XCTAssertTrue(app.staticTexts["trial.saved"].waitForExistence(timeout: 8))
    }

    func testCompareShareAndFamilyImport() {
        start(["-sample"])
        tap("tab.trials")
        tap("trial.compare", scroll: true)
        tap("compare.share", scroll: true)
        let share = button("share.image")
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: share)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        tap("share.image", scroll: true)
        XCTAssertTrue(app.staticTexts["share.requested"].waitForExistence(timeout: 8))
        tap("sheet.done")
        tap("tab.family")
        tap("family.paste", scroll: true)
        tap("family.merge", scroll: true)
        XCTAssertTrue(button("family.merge").waitForNonExistence(timeout: 5))
        tap("tab.history")
        XCTAssertTrue(app.staticTexts["Laundry · Scoop"].waitForExistence(timeout: 8))
    }

    func testTrialExpiryLeavesSingleBoxAndHistoryAndPurchaseEntry() {
        start(["-expired"])
        XCTAssertTrue(button("log.scoop.0").exists)
        XCTAssertTrue(button("box.unlock.1").exists)
        tap("log.scoop.0")
        XCTAssertTrue(app.staticTexts["log.feedback"].waitForExistence(timeout: 6))
        tap("tab.history")
        XCTAssertTrue(app.staticTexts["Laundry · Deep clean"].waitForExistence(timeout: 6))
        tap("tab.boxes")
        tap("home.settings")
        tap("settings.pro", scroll: true)
        XCTAssertTrue(button("paywall.restore").waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["The 30-day trial has ended."].exists)
    }

    func testRatingRequestAppearsAfterUndoWindowAndOnlyOnce() {
        start(["-review"])
        tap("log.scoop.0")
        XCTAssertTrue(app.staticTexts["review.requested"].waitForExistence(timeout: 10))
        start(["-review"], reset: false)
        tap("tab.history")
        tap("history.edit.0")
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 6))
        undo.tap()
        XCTAssertTrue(app.staticTexts["No matching logs."].waitForExistence(timeout: 6))
        tap("tab.boxes")
        tap("log.scoop.0")
        let repeated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"),
                                                  object: app.staticTexts["review.requested"])
        XCTAssertEqual(XCTWaiter.wait(for: [repeated], timeout: 4), .timedOut)
    }

    func testStoreScreenshots() {
        for language in ["en", "zh-Hans", "zh-Hant"] {
            start(["-sample"], language: language)
            snapshot("store-\(language)-\(scenes[0])")
            tap("log.scoop.0")
            XCTAssertTrue(app.staticTexts["log.feedback"].waitForExistence(timeout: 6))
            snapshot("store-\(language)-\(scenes[1])")

            start(["-sample"], language: language)
            tap("box.reminders.0", scroll: true)
            XCTAssertTrue(button("reminders.scoop.24").waitForExistence(timeout: 6))
            snapshot("store-\(language)-\(scenes[2])")
            tap("sheet.done")
            tap("tab.trials")
            tap("trial.compare", scroll: true)
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 6))
            snapshot("store-\(language)-\(scenes[3])")
            tap("sheet.done")
            tap("tab.family")
            tap("family.paste", scroll: true)
            let merge = button("family.merge")
            XCTAssertTrue(merge.waitForExistence(timeout: 6))
            if !merge.isHittable { app.swipeUp() }
            snapshot("store-\(language)-\(scenes[4])")
        }
    }

    func testPaidScreenshot() {
        start(["-paywall", "-expired"], language: "zh-Hans")
        XCTAssertTrue(app.staticTexts["paywall.title"].waitForExistence(timeout: 10))
        snapshot("paid-01-paywall")
    }
}
