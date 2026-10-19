import XCTest

/// The widget on a real home screen (the simulator's SpringBoard and iOS's own widget renderer): adds the Medium
/// widget the way a person does, then taps it (it should open the app). Each step is printed ("STEP …") and leaves a pause so the
/// host can take a screenshot (xcrun simctl io <sim> screenshot) — see ios/scripts/test-widget.sh.
final class WidgetTests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func step(_ s: String, wait: UInt32 = 3) {
        print("STEP \(s)")
        sleep(wait)
    }

    private func tapFirst(_ labels: [String], in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        for l in labels {
            for q in [app.buttons[l], app.staticTexts[l], app.cells[l], app.otherElements[l]] where q.waitForExistence(timeout: timeout / Double(labels.count)) {
                q.tap()
                return true
            }
        }
        return false
    }

    func testAddMediumWidgetAndOpenApp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-wbPlay", "blinding lights the weeknd"]
        app.launch()
        step("app playing", wait: 14)

        XCUIDevice.shared.press(.home)
        step("home")
        // Edit mode: long-press an empty spot.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 2)
        step("edit mode")
        if !tapFirst(["Edit"], in: springboard) { print("FAIL no Edit button: \(springboard.debugDescription.prefix(3000))") }
        step("edit menu", wait: 2)
        if !tapFirst(["Add Widget", "Add Widgets", "Widgets"], in: springboard) { print("FAIL no Add Widget: \(springboard.debugDescription.prefix(3000))") }
        step("gallery")
        let search = springboard.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("WreckBox")
        }
        step("searched")
        if !tapFirst(["WreckBox Player"], in: springboard) { print("FAIL no WreckBox Player in gallery: \(springboard.debugDescription.prefix(4000))") }
        step("sizes")
        // Sizes go small → medium: swipe to Medium.
        springboard.swipeLeft(); sleep(1)
        step("medium chosen")
        // The button's label includes its icon ("Add Widget" with a +): match loosely.
        let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget'")).firstMatch
        if add.waitForExistence(timeout: 5) { add.tap() } else { print("FAIL no Add Widget button: \(springboard.buttons.allElementsBoundByIndex.map(\.label))") }
        step("added", wait: 3)
        _ = tapFirst(["Done"], in: springboard)
        step("widget on home", wait: 6)

        // Tap the widget: it opens the app (Now playing).
        let widget = springboard.otherElements.matching(NSPredicate(format: "label CONTAINS 'WreckBox'")).firstMatch
        print("widget exists: \(widget.exists) frame: \(widget.frame)")
        if widget.exists {
            widget.tap()
            print(app.wait(for: .runningForeground, timeout: 8) ? "OK app opened" : "FAIL app did not open")
            step("tapped widget", wait: 4)
        }
        step("end", wait: 2)
    }
}
