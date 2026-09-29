import XCTest
@testable import AXKit

final class TraitsTests: XCTestCase {
    func testNativeControlsStayInTheBackground() {
        for operation in [Gesture.setDate, .setText, .setNumber, .ensure, .choose, .menu, .select] {
            XCTAssertEqual(operation.native.front, .never, operation.rawValue)
        }
    }

    func testPageControlsComeInFront() {
        for operation in [Gesture.setDate, .setText, .press, .choose, .insert, .pick] {
            XCTAssertEqual(operation.page.front, .always, operation.rawValue)
        }
        XCTAssertEqual(Gesture.setDate.page.handsOff, .keyboard)
        XCTAssertTrue(Gesture.place.page.invalidatesElements)
        XCTAssertFalse(Gesture.place.native.invalidatesElements)
    }

    func testForegroundGesturesAreAlwaysInFront() {
        for operation in [Gesture.paste, .shortcut, .copy, .drag, .activate] {
            XCTAssertEqual(operation.native.front, .always, operation.rawValue)
        }
        XCTAssertEqual(Gesture.drag.native.handsOff, .pointer)
        XCTAssertTrue(Gesture.paste.native.borrowsClipboard)
    }

    func testCombinedTakesTheMostAnyStepAsks() {
        let together = Traits.combined([Gesture.setText.native, Gesture.drag.native, Gesture.copy.native])
        XCTAssertEqual(together.front, .always)
        XCTAssertEqual(together.handsOff, .pointer)
        XCTAssertTrue(together.borrowsClipboard)
        XCTAssertFalse(together.safeToRetry)
        XCTAssertEqual(together.reversible, .no)
        XCTAssertEqual(Traits.combined([]).warnings, [])
    }

    func testAPressIsIrreversibleByItsTitle() {
        XCTAssertEqual(Gesture.press.traits(in: nil, target: "Send").reversible, .no)
        XCTAssertEqual(Gesture.press.traits(in: nil, target: "Ne pas enregistrer").reversible, .no)
        XCTAssertEqual(Gesture.press.traits(in: nil, target: "Bold").reversible, .dependsOnTarget)
        XCTAssertEqual(Gesture.setText.traits(in: nil, target: "Send").reversible, .yes)
    }

    func testTheElectronFixtureHasPages() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/electron-app/node_modules/electron/dist/Electron.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: app.path), "npm install in Fixtures/electron-app")
        XCTAssertTrue(App.bundleHasEngine(app))
        XCTAssertFalse(App.bundleHasEngine(URL(fileURLWithPath: "/System/Applications/TextEdit.app")))
    }
}
