//
//  NavigationUITests.swift
//  GrowGuardUITests
//
//  End-to-end navigation coverage for the per-tab NavigationStack restructure.
//  Each test launches the app fresh; onboarding is skipped via an NSArgumentDomain
//  override and the language is forced to English so tab/navigation-bar titles are
//  deterministic. Overview → Details uses the `-uiTestSeedDevice` launch seam to
//  populate a known device without BLE hardware.
//

import XCTest

final class NavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Defensively dismiss any system permission dialog (e.g. Bluetooth) that
        // could appear when the Add Device tab starts scanning.
        addUIInterruptionMonitor(withDescription: "System Dialog") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    // MARK: - Launch helper

    private func launchApp(seedDevice: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            // Skip onboarding (UserDefaults argument-domain override).
            "-veit.pro.showOnboarding", "1",
            // Deterministic, English titles for tab bar and navigation bars.
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        if seedDevice {
            app.launchArguments += ["-uiTestSeedDevice"]
        }
        app.launch()
        return app
    }

    // MARK: - Tests

    /// App launches straight into the tab UI (onboarding skipped) with all three tabs.
    func testLaunchSkipsOnboardingAndShowsTabs() {
        let app = launchApp()

        XCTAssertTrue(
            app.navigationBars["Overview"].waitForExistence(timeout: 20),
            "Should land on the Overview tab without the onboarding screen"
        )

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["Menu"].exists, "Overview tab missing")
        XCTAssertTrue(tabBar.buttons["Add"].exists, "Add Device tab missing")
        XCTAssertTrue(tabBar.buttons["Settings"].exists, "Settings tab missing")
    }

    /// Switching between all three tabs shows each tab's root screen.
    func testTabSwitchingBetweenAllTabs() {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20))

        app.tabBars.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add Device"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Menu"].tap()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 5))
    }

    /// The Add Device screen can push the manual-add flow and navigate back —
    /// the navigation the user reported as broken.
    func testAddDeviceManualNavigationPushAndBack() {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20))

        app.tabBars.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add Device"].waitForExistence(timeout: 5))

        let manualCard = app.buttons["addManuallyCard"]
        XCTAssertTrue(manualCard.waitForExistence(timeout: 5))
        manualCard.tap()

        XCTAssertTrue(
            app.navigationBars["Add Flower"].waitForExistence(timeout: 5),
            "Tapping 'Add Plant Manually' should push the Add Flower screen"
        )

        // Back button returns to the Add Device root.
        app.navigationBars["Add Flower"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Add Device"].waitForExistence(timeout: 5))
    }

    /// Each tab keeps its own navigation stack: a screen pushed on the Add Device
    /// tab survives a round-trip to another tab. This is the core regression the
    /// restructure fixes (previously one shared stack wrapped the whole TabView).
    func testNavigationStateIsRetainedPerTab() {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20))

        // Push the manual-add flow on the Add Device tab.
        app.tabBars.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Add Device"].waitForExistence(timeout: 5))
        app.buttons["addManuallyCard"].tap()
        XCTAssertTrue(app.navigationBars["Add Flower"].waitForExistence(timeout: 5))

        // Visit Overview, then return to Add Device.
        app.tabBars.buttons["Menu"].tap()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Add"].tap()

        // The pushed screen is still there — the Add Device stack was not reset.
        XCTAssertTrue(
            app.navigationBars["Add Flower"].waitForExistence(timeout: 5),
            "Add Device tab should retain its pushed screen across tab switches"
        )
    }

    /// Overview → Details push works against a seeded device (the second reported
    /// bug), and back returns to the Overview list.
    func testOverviewToDeviceDetailsNavigation() {
        let app = launchApp(seedDevice: true)
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20))

        let card = app.buttons["deviceCard-UITEST-DEVICE-0001"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Seeded device card should appear")
        card.tap()

        XCTAssertTrue(
            app.navigationBars["UITest Plant"].waitForExistence(timeout: 10),
            "Tapping the device should push its detail screen"
        )
        XCTAssertTrue(app.otherElements["deviceDetailScreen"].exists
                      || app.scrollViews["deviceDetailScreen"].exists)

        // Back returns to the Overview list.
        app.navigationBars["UITest Plant"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 5))
    }
}
