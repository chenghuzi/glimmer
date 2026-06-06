import XCTest
@testable import GlimmerCore

final class AsdBehaviorParserTests: XCTestCase {
    func testBackgroundCodeBuildsB10Report() throws {
        let report = try XCTUnwrap(AsdBehaviorParser.parse("000000000"))

        XCTAssertEqual(report.labelCode, "000000000")
        XCTAssertEqual(report.features["B01"], false)
        XCTAssertEqual(report.features["B09"], false)
        XCTAssertEqual(report.features["B10"], true)
        XCTAssertEqual(report.overall, "background")
        XCTAssertEqual(
            report.jsonString,
            #"{"schema_version":"1.0","features":{"B01":false,"B02":false,"B03":false,"B04":false,"B05":false,"B06":false,"B07":false,"B08":false,"B09":false,"B10":true},"overall":"background"}"#
        )
    }

    func testObservedCodeBuildsOrderedReport() throws {
        let report = try XCTUnwrap(AsdBehaviorParser.parse("100000001"))

        XCTAssertEqual(report.features["B01"], true)
        XCTAssertEqual(report.features["B08"], false)
        XCTAssertEqual(report.features["B09"], true)
        XCTAssertEqual(report.features["B10"], false)
        XCTAssertEqual(report.overall, "behavior_features_observed")
        XCTAssertEqual(
            report.jsonString,
            #"{"schema_version":"1.0","features":{"B01":true,"B02":false,"B03":false,"B04":false,"B05":false,"B06":false,"B07":false,"B08":false,"B09":true,"B10":false},"overall":"behavior_features_observed"}"#
        )
    }

    func testInvalidCodesAreRejected() {
        XCTAssertNil(AsdBehaviorParser.parse("00000000"))
        XCTAssertNil(AsdBehaviorParser.parse("0000000000"))
        XCTAssertNil(AsdBehaviorParser.parse("00000000x"))
        XCTAssertNil(AsdBehaviorParser.parse("000000000\nextra"))
    }
}
