import XCTest
@testable import FeatBitClient

final class EvalResultTests: XCTestCase {
    func test_flagNotFound_reason_is_wire_compatible() {
        // Mutation: renaming "flag not found" breaks .NET / Kotlin wire parity.
        XCTAssertEqual(EvalResult.flagNotFound.reason, "flag not found")
        XCTAssertFalse(EvalResult.flagNotFound.isValid)
        XCTAssertEqual(EvalResult.flagNotFound.value, "")
    }

    func test_found_reason_uses_flag_matchReason() {
        let flag = FeatureFlag(id: "k", variation: "v", matchReason: "TARGET_MATCH")
        let result: EvalResult = .found(flag)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.reason, "TARGET_MATCH")
        XCTAssertEqual(result.value, "v")
    }

    func test_pattern_match_extracts_flag() {
        let flag = FeatureFlag(id: "k", variation: "v", matchReason: "TARGET_MATCH")
        let result: EvalResult = .found(flag)
        guard case .found(let extracted) = result else {
            XCTFail("expected .found")
            return
        }
        XCTAssertEqual(extracted.id, "k")
        XCTAssertEqual(extracted.variation, "v")
    }

    func test_notFound_custom_reason_echoes_associated_value() {
        // Mutation: replacing `case .notFound(let reason): return reason` with a hard-coded
        // string would silently pass test #1 (uses the static) but fail here.
        let result: EvalResult = .notFound(reason: "type mismatch")
        XCTAssertEqual(result.reason, "type mismatch")
        XCTAssertEqual(result.value, "")
        XCTAssertFalse(result.isValid)
    }
}
