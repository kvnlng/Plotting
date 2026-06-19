//
//  MurmurUITests.swift
//  MurmurUITests
//
//  Created by Kevin Long on 6/14/26.
//

import XCTest

final class MurmurUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tier 1: smoke tests

    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    @MainActor
    func testEmptyStateIsVisible() throws {
        let app = XCUIApplication()
        app.launch()

        let prompt = app.staticTexts["empty-state-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 3), "Empty-state prompt should appear on cold launch")

        let openButton = app.buttons["empty-state-open-button"]
        XCTAssertTrue(openButton.exists, "Empty-state Open CSV button should be present")
        XCTAssertTrue(openButton.isHittable, "Empty-state Open CSV button should be hittable")
    }

    @MainActor
    func testToolbarOpenButtonExists() throws {
        let app = XCUIApplication()
        app.launch()

        let toolbarButton = app.buttons["toolbar-open-button"]
        XCTAssertTrue(toolbarButton.waitForExistence(timeout: 3),
                      "Toolbar Open CSV button should be present")
    }

    // MARK: - Tier 3: synthetic Recording fixture loaded via launch argument

    @MainActor
    func testSyntheticFixtureRendersBedsideView() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let bedside = app.descendants(matching: .any).matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 5),
                      "BedsideView should appear once the synthetic fixture loads")

        // The lead chip bar should be present with chips for every synthetic
        // lead — Focus mode default still renders the chip bar even though
        // only one channel panel is visible at a time.
        let chipBar = app.descendants(matching: .any).matching(identifier: "lead-chip-bar").firstMatch
        XCTAssertTrue(chipBar.waitForExistence(timeout: 3),
                      "Lead chip bar should be present so the user can pick a lead")
        let chipForV1 = app.descendants(matching: .any).matching(identifier: "lead-chip-V1").firstMatch
        XCTAssertTrue(chipForV1.exists, "Chip for V1 should be present in the lead bar")

        // First synthetic lead is "I" — focus mode defaults to it.
        let focusedPanel = app.descendants(matching: .any).matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(focusedPanel.waitForExistence(timeout: 5),
                      "Channel panel for the default-focused lead (I) should render")

        // Empty state is gone.
        let prompt = app.staticTexts["empty-state-prompt"]
        XCTAssertFalse(prompt.exists, "Empty-state prompt should not be visible once a recording is loaded")
    }
}
