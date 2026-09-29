import XCTest
@testable import AXKit

final class BrowserTests: XCTestCase {
    func testTheMemorySuffixIsDropped() {
        XCTAssertEqual(Browser.cleanTitle("AXKit Alpha page - Memory usage - 29.6 MB"), "AXKit Alpha page")
        XCTAssertEqual(Browser.cleanTitle("Inbox - Gmail"), "Inbox - Gmail")
    }

    func testEveryWordMustMatch() {
        XCTAssertTrue(Browser.matches("alpha", "AXKit Alpha page"))
        XCTAssertTrue(Browser.matches("page ALPHA", "AXKit Alpha page"))
        XCTAssertTrue(Browser.matches("cafe", "Le Café du coin"))
        XCTAssertFalse(Browser.matches("alpha bravo", "AXKit Alpha page"))
        XCTAssertFalse(Browser.matches("  ", "AXKit Alpha page"))
    }
}
