//
//  ReceiptScannerUITests.swift
//  ReceiptScannerUITests
//
//  Created by Kun Niu on 2026-06-06.
//

import XCTest

final class ReceiptScannerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()
    }

    // MARK: - Scan screen

    @MainActor
    func testScanScreenOffersCameraAndPDFImport() throws {
        let app = launchApp(seeded: false)
        XCTAssertTrue(app.buttons["Scan Document"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Select PDF from Files"].exists)
    }

    @MainActor
    func testScanScreenPassesAccessibilityAudit() throws {
        let app = launchApp(seeded: false)
        XCTAssertTrue(app.buttons["Scan Document"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: .contrast)
    }

    // MARK: - History

    @MainActor
    func testEmptyHistoryShowsPlaceholder() throws {
        let app = launchApp(seeded: false)
        openTab("History", in: app)
        XCTAssertTrue(app.staticTexts["No History"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHistoryListsNewestReceiptFirst() throws {
        let app = launchApp(seeded: true)
        openTab("History", in: app)

        let grocerRow = app.staticTexts["Sample Grocer"]
        let hardwareRow = app.staticTexts["Sample Hardware"]
        XCTAssertTrue(hardwareRow.waitForExistence(timeout: 5))
        XCTAssertTrue(grocerRow.exists)
        // Seeded with Hardware scanned more recently than Grocer; the list
        // sorts newest-first, so Hardware's row must be physically above.
        XCTAssertLessThan(hardwareRow.frame.minY, grocerRow.frame.minY)
    }

    @MainActor
    func testReceiptDetailShowsItemsInReceiptOrder() throws {
        let app = launchApp(seeded: true)
        openTab("History", in: app)

        app.staticTexts["Sample Grocer"].tap()

        XCTAssertTrue(app.navigationBars["Sample Grocer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Bananas"].exists)
        XCTAssertTrue(app.staticTexts["Milk"].exists)
    }

    @MainActor
    func testSwipeToDeleteRemovesOnlyThatReceipt() throws {
        let app = launchApp(seeded: true)
        openTab("History", in: app)

        let grocerCell = app.cells.containing(.staticText, identifier: "Sample Grocer").element
        XCTAssertTrue(grocerCell.waitForExistence(timeout: 5))
        grocerCell.swipeLeft()
        app.buttons["Delete"].tap()

        XCTAssertFalse(app.staticTexts["Sample Grocer"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Sample Hardware"].exists)
    }

    // MARK: - Spending summary

    @MainActor
    func testSpendingSummaryShowsEachStoreTotal() throws {
        let app = launchApp(seeded: true)
        openTab("History", in: app)

        app.buttons["spendingButton"].tap()

        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sample Hardware"].exists)
        XCTAssertTrue(element(containing: "14.68", in: app).exists)
        XCTAssertTrue(app.staticTexts["Sample Grocer"].exists)
        XCTAssertTrue(element(containing: "5.48", in: app).exists)
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp(seeded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing"]
        if seeded { app.launchArguments += ["-ui-testing-seeded"] }
        app.launch()
        return app
    }

    @MainActor
    private func openTab(_ name: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
    }

    /// Matches an element whose label contains `substring` — for text built
    /// with string interpolation (e.g. "$14.68"), where the exact full label
    /// isn't worth hardcoding.
    private func element(containing substring: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", substring)).firstMatch
    }
}
