import XCTest
@testable import GlimmerCore

final class AsdExplanationPromptsTests: XCTestCase {
    func testExplanationSystemKeepsScreeningBoundaryWithoutCodeOnlyConstraint() {
        XCTAssertTrue(AsdExplanationPrompts.system.contains("筛查支持"))
        XCTAssertTrue(AsdExplanationPrompts.system.contains("不是医学结论"))
        XCTAssertTrue(AsdExplanationPrompts.system.contains("视频"))
        XCTAssertTrue(AsdExplanationPrompts.system.contains("音频"))
        XCTAssertFalse(AsdExplanationPrompts.system.contains("只返回 B01 到 B09 的 9 位二进制标签码"))
        XCTAssertFalse(AsdExplanationPrompts.system.contains("诊断"))
    }

    func testExplanationUserPromptDoesNotAskForReclassification() {
        XCTAssertTrue(AsdExplanationPrompts.userInstruction.contains("同一段视频"))
        XCTAssertTrue(AsdExplanationPrompts.userInstruction.contains("不要重新输出 9 位二进制码"))
        XCTAssertTrue(AsdExplanationPrompts.userInstruction.contains("不要重新分类"))
    }

    func testAssistantResultContextKeepsUserFacingSummaryOnly() throws {
        let report = try XCTUnwrap(AsdBehaviorParser.parse("100000001"))
        let context = AsdExplanationPrompts.assistantResultContext(report: report)

        XCTAssertTrue(context.contains("缺乏或回避眼神接触"))
        XCTAssertTrue(context.contains("上肢刻板动作"))
        XCTAssertFalse(context.contains("9-bit code"))
        XCTAssertFalse(context.contains("B01"))
        XCTAssertFalse(context.contains("B10"))
        XCTAssertFalse(context.contains("true"))
        XCTAssertFalse(context.contains("false"))
        XCTAssertFalse(context.contains("诊断"))
    }
}
