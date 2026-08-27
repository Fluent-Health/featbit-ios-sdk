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

    // MARK: Aggressive pinning (Task 27) — alloc-free bool.

    func testBoolAcceptsMixedCase() {
        // Mutation: replacing compare(_:options:.caseInsensitive) with plain
        // == "true" would reject mixed-case inputs.
        XCTAssertEqual(ValueConverters.bool("TRUE"), true)
        XCTAssertEqual(ValueConverters.bool("True"), true)
        XCTAssertEqual(ValueConverters.bool("tRuE"), true)
        XCTAssertEqual(ValueConverters.bool("false"), false)
        XCTAssertEqual(ValueConverters.bool("FALSE"), false)
        XCTAssertEqual(ValueConverters.bool("fAlSe"), false)
    }

    func testBoolTrimsWhitespace() {
        XCTAssertEqual(ValueConverters.bool("  true  "), true)
        XCTAssertEqual(ValueConverters.bool("\ttrue\t"), true)
        XCTAssertEqual(ValueConverters.bool(" false "), false)
    }

    func testBoolRejectsNearMatches() {
        // Mutation: hasPrefix("true") would accept "trues"; startsWith would
        // accept "trueX". compare(_:options:.caseInsensitive) tests full-string
        // equivalence, so all near-matches must be rejected.
        XCTAssertNil(ValueConverters.bool("trues"))
        XCTAssertNil(ValueConverters.bool("trueX"))
        XCTAssertNil(ValueConverters.bool("yes"))
        XCTAssertNil(ValueConverters.bool("1"))
        XCTAssertNil(ValueConverters.bool("0"))
        XCTAssertNil(ValueConverters.bool(""))
    }
}
