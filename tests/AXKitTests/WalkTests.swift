import AppKit
import XCTest
@testable import AXKit

final class WalkTests: XCTestCase {
    func testShortHashIsFNV1a() {
        XCTAssertEqual(Walk.shortHash(""), "811c9dc5")
        XCTAssertEqual(Walk.shortHash("a"), "e40c292c")
    }

    func testKeyJoinsRoleNameAndPath() {
        XCTAssertEqual(Walk.key(role: "AXButton", name: "Send", path: "/AXWindow"),
                       Walk.shortHash("AXButton\u{1}Send\u{1}/AXWindow"))
    }

    func testPathSkipsWrappersAndRepeats() {
        XCTAssertEqual(Walk.path(below: "", role: "AXWindow"), "/AXWindow")
        XCTAssertEqual(Walk.path(below: "/AXWindow", role: "AXGroup"), "/AXWindow")
        XCTAssertEqual(Walk.path(below: "/AXWindow/AXList", role: "AXList"), "/AXWindow/AXList")
        XCTAssertEqual(Walk.path(below: "/AXWindow", role: "AXList"), "/AXWindow/AXList")
    }

    func testGlob() {
        XCTAssertTrue(Glob.matches("* ??/??/?? ??:?? - ??:??", "Mon 28/09/26 15:00 - 15:30"))
        XCTAssertTrue(Glob.matches("new event*", "New Event • Calendar"))
        XCTAssertFalse(Glob.matches("Start date", "Start time"))
    }

    func testRectRounds() {
        XCTAssertEqual(Rect(CGRect(x: 1.4, y: 2.6, width: 10.5, height: 3.2)),
                       Rect(CGRect(x: 1, y: 3, width: 11, height: 3)))
    }

    func testNodeRoundTripsThroughJSON() throws {
        let node = Node(role: "AXButton", subrole: nil, name: "OK", value: nil, identifier: nil,
                        dom: "ok", frame: Rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                        actions: ["AXPress"], states: ["focused"], depth: 2, parent: 0, key: "k")
        let data = try JSONEncoder().encode(node)
        XCTAssertEqual(try JSONDecoder().decode(Node.self, from: data), node)
    }

    func testErrorNamesTheCall() {
        XCTAssertEqual(AXKitError.ax(.illegalArgument, "set AXValue").description,
                       "set AXValue: illegal argument (-25201)")
        XCTAssertEqual(AXKitError.timedOut("launch com.apple.Calculator").description,
                       "launch com.apple.Calculator: timed out")
    }

    func testValueIsReadableFailsClosed() {
        XCTAssertTrue(Element.valueIsReadable(role: "AXTextField", subrole: nil, subroleRead: .noValue))
        XCTAssertTrue(Element.valueIsReadable(role: "AXTextField", subrole: nil, subroleRead: .attributeUnsupported))
        XCTAssertTrue(Element.valueIsReadable(role: "AXTextField", subrole: "AXSearchField", subroleRead: .success))
        XCTAssertFalse(Element.valueIsReadable(role: "AXTextField", subrole: "AXSecureTextField", subroleRead: .success))
        XCTAssertFalse(Element.valueIsReadable(role: "AXSecureTextField", subrole: nil, subroleRead: .noValue))
        XCTAssertFalse(Element.valueIsReadable(role: "AXSecureTextField", subrole: "AXSearchField", subroleRead: .success))
        XCTAssertFalse(Element.valueIsReadable(role: "AXTextField", subrole: nil, subroleRead: .cannotComplete))
        XCTAssertFalse(Element.valueIsReadable(role: nil, subrole: nil, subroleRead: .apiDisabled))
        XCTAssertFalse(Element.valueIsReadable(role: "AXTextField", subrole: nil, subroleRead: .failure))
    }

    func testSettledIsFalseWhenNothingCanBeWatched() {
        XCTAssertFalse(Wait.settled(App(pid: -1), quiet: 0.05, timeout: 0.5))
    }

    /// Needs the Accessibility permission for the process running the tests.
    func testWalkOfFinderWhenTrusted() throws {
        try XCTSkipUnless(App.isTrusted, "no Accessibility permission")
        let app = try XCTUnwrap(App.named("com.apple.finder"))
        let result = Walk.run(from: app.element, options: WalkOptions(depth: 2, budget: 50))
        XCTAssertEqual(result.nodes.first?.role, "AXApplication")
    }
}

final class FindTests: XCTestCase {
    /// Needs the Accessibility permission for the process running the tests.
    func testParentsPointIntoTheResult() throws {
        try XCTSkipUnless(App.isTrusted, "no Accessibility permission")
        let app = try XCTUnwrap(App.named("com.apple.finder"))
        let options = WalkOptions(depth: 3, budget: 50)
        let everything = Walk.find(in: app.element, options: options).map(\.1.parent)
        XCTAssertEqual(everything, Walk.run(from: app.element, options: options).nodes.map(\.parent))
        let role = try XCTUnwrap(Walk.run(from: app.element, options: options).nodes.dropFirst().first?.role)
        let found = Walk.find(in: app.element, role: role, options: options).map(\.1)
        XCTAssertNil(try XCTUnwrap(found.first).parent)
        for node in found {
            guard let parent = node.parent else { continue }
            XCTAssertTrue(found.indices.contains(parent))
            XCTAssertEqual(found[parent].role, role)
        }
    }
}
