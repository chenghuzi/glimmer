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
        XCTAssertEqual(report.conclusionTitle, "未注意到明显自闭症倾向类型行为")
        XCTAssertTrue(report.conclusionText.contains("系统暂未观察到明显的可关注行为特征"))
        XCTAssertTrue(report.conclusionText.contains("温馨提示"))
        XCTAssertTrue(report.conclusionText.contains("不构成医学诊断"))
        XCTAssertFalse(report.conclusionText.contains("B01"))
        XCTAssertFalse(report.conclusionText.contains("false"))
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
        XCTAssertEqual(report.conclusionTitle, "注意到 2 类可关注行为")
        XCTAssertTrue(report.conclusionText.contains("系统识别到以下值得关注的行为特征"))
        XCTAssertTrue(report.conclusionText.contains("01｜缺乏或回避眼神接触"))
        XCTAssertTrue(report.conclusionText.contains("02｜上肢刻板动作"))
        XCTAssertTrue(report.conclusionText.contains("结果说明"))
        XCTAssertFalse(report.conclusionText.contains("B01"))
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
