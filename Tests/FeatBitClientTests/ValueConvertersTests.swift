import XCTest
@testable import FeatBitClient

final class ValueConvertersTests: XCTestCase {
    func testBool() {
        XCTAssertEqual(ValueConverters.bool("true"), true)
        XCTAssertEqual(ValueConverters.bool("  TRUE "), true)
        XCTAssertEqual(ValueConverters.bool("False"), false)
        XCTAssertNil(ValueConverters.bool("yes"))
        XCTAssertNil(ValueConverters.bool(""))
    }

    func testInt() {
        XCTAssertEqual(ValueConverters.int(" 42 "), 42)
        XCTAssertEqual(ValueConverters.int("-7"), -7)
        XCTAssertNil(ValueConverters.int("3.5"))
        XCTAssertNil(ValueConverters.int("abc"))
    }

    func testDoubleAndFloat() {
        XCTAssertEqual(ValueConverters.double(" 3.14 "), 3.14)
        XCTAssertEqual(ValueConverters.float("2.5"), 2.5)
        XCTAssertNil(ValueConverters.double("x"))
    }

    func testString() {
        XCTAssertEqual(ValueConverters.string("  keep spaces  "), "  keep spaces  ")
    }
}
