import AppKit
import XCTest
@testable import AXKit

final class ReadTests: XCTestCase {
    private func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Rect {
        Rect(CGRect(x: x, y: y, width: w, height: h))
    }

    /// A window with a scroll area over its top half.
    private var page: [Record] {
        [
            Record(role: "AXWindow", title: "Inbox", frame: box(0, 0, 100, 100), depth: 0),
            Record(role: "AXScrollArea", frame: box(0, 0, 100, 50), depth: 1, parent: 0),
            Record(role: "AXGroup", description: "Message from Ana", frame: box(0, 10, 100, 20),
                   depth: 2, parent: 1),
            Record(role: "AXStaticText", value: "Lunch at noon?", frame: box(0, 10, 100, 20),
                   depth: 3, parent: 2),
            Record(role: "AXStaticText", value: "Scrolled away", frame: box(0, 60, 100, 20),
                   depth: 2, parent: 1),
            Record(role: "AXImage", description: "Ana", depth: 2, parent: 1),
            Record(role: "AXTextField", subrole: "AXSecureTextField", frame: box(0, 70, 100, 20),
                   depth: 1, parent: 0),
            Record(role: "AXButton", title: "Send", frame: box(0, 80, 100, 20), depth: 1, parent: 0),
            Record(role: "AXButton", title: "Off screen", frame: box(200, 0, 10, 10), depth: 1, parent: 0),
        ]
    }

    func testVisibleDropsWhatTheScrollAreaAndWindowCut() {
        XCTAssertEqual(Read.visible(page), [0, 1, 2, 3, 5, 6, 7])
    }

    func testVisibleTextReadsValuesAndLeafLabels() {
        XCTAssertEqual(Read.visibleText(page), ["Lunch at noon?", "Ana", "Send"])
    }

    func testHeadingsTakeTheLevelAndTheText() {
        let records = [
            Record(role: "AXWebArea", title: "Docs", depth: 0),
            Record(role: "AXHeading", title: "Install", number: 2, depth: 1, parent: 0),
            Record(role: "AXHeading", number: 3, depth: 1, parent: 0),
            Record(role: "AXStaticText", value: "On a", depth: 2, parent: 2),
            Record(role: "AXGroup", depth: 2, parent: 2),
            Record(role: "AXStaticText", value: "Mac", depth: 3, parent: 4),
            Record(role: "AXStaticText", value: "Body", depth: 1, parent: 0),
            Record(role: "AXHeading", title: "Odd", number: .nan, depth: 1, parent: 0),
        ]
        XCTAssertEqual(Read.headings(records), [
            Heading(index: 1, level: 2, text: "Install"),
            Heading(index: 2, level: 3, text: "On a Mac"),
            Heading(index: 7, level: nil, text: "Odd"),
        ])
    }

    func testLandmarksComeFromSubroles() {
        let records = [
            Record(role: "AXWebArea", depth: 0),
            Record(role: "AXGroup", subrole: "AXLandmarkNavigation", description: "Sidebar", depth: 1, parent: 0),
            Record(role: "AXGroup", subrole: "AXLandmarkMain", depth: 1, parent: 0),
            Record(role: "AXGroup", subrole: "AXApplicationLog", title: "Messages", depth: 2, parent: 2),
            Record(role: "AXGroup", subrole: "AXApplicationGroup", depth: 2, parent: 2),
            Record(role: "AXGroup", subrole: "AXLandmarkRegion", title: "Composer", depth: 1, parent: 0),
        ]
        XCTAssertEqual(Read.landmarks(records), [
            Landmark(index: 1, kind: .navigation, label: "Sidebar"),
            Landmark(index: 2, kind: .main, label: nil),
            Landmark(index: 3, kind: .log, label: "Messages"),
            Landmark(index: 5, kind: .region, label: "Composer"),
        ])
    }

    func testSecureAndEditableFollowRoleAndSubrole() {
        let password = Record(role: "AXTextField", subrole: "AXSecureTextField")
        let field = Record(role: "AXTextField")
        XCTAssertEqual([password.isSecure, password.isEditable], [true, true])
        XCTAssertEqual([field.isSecure, field.isEditable], [false, true])
        XCTAssertEqual(Record(role: "AXStaticText").isEditable, false)
    }

    /// Keys are stored by agent skills. A new key format raises Walk.keyVersion.
    func testKeyFormatHolds() {
        XCTAssertEqual(Walk.key(role: "AXButton", name: "Send", path: "/AXWindow/AXWebArea"), "87c491eb")
    }

    /// Needs the Accessibility permission. Holds on any Finder: CI's has no window.
    func testWalkOfFinderGivesATreeWhenTrusted() throws {
        try XCTSkipUnless(App.isTrusted, "no Accessibility permission")
        let app = try XCTUnwrap(App.named("com.apple.finder"))
        let result = Read.walk(from: app.element, options: ReadOptions(budget: 50, depth: 3))
        XCTAssertEqual(result.records.first?.role, "AXApplication")
        XCTAssertNil(result.records.first?.parent)
        for (index, record) in result.records.enumerated().dropFirst() {
            let parent = try XCTUnwrap(record.parent)
            XCTAssertLessThan(parent, index)
            XCTAssertEqual(record.depth, result.records[parent].depth + 1)
        }
        XCTAssertLessThanOrEqual(result.records.count, 50)
        XCTAssertGreaterThanOrEqual(result.calls, result.records.count)
    }

    /// Needs the Accessibility permission.
    func testStopEndsTheReadAsTheDeadlineDoesWhenTrusted() throws {
        try XCTSkipUnless(App.isTrusted, "no Accessibility permission")
        let app = try XCTUnwrap(App.named("com.apple.finder"))
        let result = Read.walk(from: app.element, options: ReadOptions(stop: { true }))
        XCTAssertEqual(result.records.count, 0)
        XCTAssertEqual(result.stopped, .deadline)
        XCTAssertTrue(Read.climb(from: app.element, options: ReadOptions(stop: { true })).isEmpty)
    }

    /// Needs the Accessibility permission, and a Finder with one child.
    func testAncestorsEndAtTheParentWhenTrusted() throws {
        try XCTSkipUnless(App.isTrusted, "no Accessibility permission")
        let app = try XCTUnwrap(App.named("com.apple.finder"))
        let children = app.element.children
        try XCTSkipIf(children.isEmpty, "this Finder shows nothing")
        let child = children[0]
        let chain = Read.ancestors(of: child)
        XCTAssertEqual(chain.map(\.record.role), ["AXApplication"])
        XCTAssertEqual(chain.first?.element, app.element)
        XCTAssertNil(Read.webArea(around: child))
    }
}
