//
//  PlottingUITests.swift
//  PlottingUITests
//
//  Created by Kevin Long on 6/14/26.
//

import XCTest

final class PlottingUITests: XCTestCase {

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

        let bedside = app.scrollViews["bedside-view"].firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 5),
                      "BedsideView should appear once the synthetic fixture loads")

        // Summary header is visible.
        let summary = app.staticTexts.matching(identifier: "bedside-summary").firstMatch
        XCTAssertTrue(summary.exists, "Bedside summary header should be present")

        // Two of the eight synthetic ECG lead panels should be visible.
        let leadII = app.descendants(matching: .any).matching(identifier: "channel-panel-II").firstMatch
        XCTAssertTrue(leadII.waitForExistence(timeout: 5), "Channel panel for II should render")
        let leadV1 = app.descendants(matching: .any).matching(identifier: "channel-panel-V1").firstMatch
        XCTAssertTrue(leadV1.exists, "Channel panel for V1 should render")

        // Empty state is gone.
        let prompt = app.staticTexts["empty-state-prompt"]
        XCTAssertFalse(prompt.exists, "Empty-state prompt should not be visible once a recording is loaded")
    }
}
