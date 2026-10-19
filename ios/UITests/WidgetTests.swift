import XCTest

/// The widgets on a real home screen (the simulator's SpringBoard and iOS's own widget renderer): adds the Large
/// widget the way a person does, then presses its buttons. Each step is printed ("STEP …") and leaves a pause so the
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

    func testAddLargeWidgetAndPressButtons() throws {
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
        // Sizes go small → medium → large: swipe to Large.
        for _ in 0..<2 { springboard.swipeLeft(); sleep(1) }
        step("large chosen")
        // The button's label includes its icon ("Add Widget" with a +): match loosely.
        let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget'")).firstMatch
        if add.waitForExistence(timeout: 5) { add.tap() } else { print("FAIL no Add Widget button: \(springboard.buttons.allElementsBoundByIndex.map(\.label))") }
        step("added", wait: 3)
        _ = tapFirst(["Done"], in: springboard)
        step("widget on home", wait: 6)

        // Press the widget's buttons: Queue tab is open by default — play the first song in it.
        let widget = springboard.otherElements.matching(NSPredicate(format: "label CONTAINS 'WreckBox'")).firstMatch
        print("widget exists: \(widget.exists) frame: \(widget.frame)")
        if widget.exists {
            let f = widget.frame
            // v6 layout, as fractions of the large widget's frame (from the widgetlab drawing).
            func tap(_ fx: CGFloat, _ fy: CGFloat) { springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.minX + fx * f.width, dy: f.minY + fy * f.height)).tap() }
            tap(0.30, 0.614)
            step("tapped queue row 1", wait: 8)
            tap(0.769, 0.219)
            step("tapped play/pause", wait: 6)
            tap(0.575, 0.457)
            step("tapped EQ tab", wait: 6)
            tap(0.84, 0.647)
            step("tapped a preset", wait: 6)
            tap(0.715, 0.457)
            step("tapped Queue tab", wait: 4)
            // Stress: the old widget went blank after a few presses. Play/pause, next, +10 s, tabs, fast.
            for i in 0..<20 {
                switch i % 5 {
                case 0: tap(0.769, 0.219)
                case 1: tap(0.90, 0.219)
                case 2: tap(0.769, 0.094)
                case 3: tap(0.575, 0.457)
                default: tap(0.715, 0.457)
                }
                Thread.sleep(forTimeInterval: 0.8)
            }
            step("after 20 fast presses", wait: 6)
            tap(0.769, 0.219)
            step("final play/pause", wait: 6)
        }
        step("end", wait: 2)
    }
}
