import XCTest
@testable import GlimmerCore

final class AsdExplanationPromptsTests: XCTestCase {
    func testExplanationSystemKeepsScreeningBoundaryWithoutCodeOnlyConstraint() {
        XCTAssertTrue(AsdExplanationPrompts.system.contains("筛查支持"))
        XCTAssertTrue(AsdExplanationPrompts.system.contains("不是医学诊断"))
        XCTAssertTrue(AsdExplanationPrompts.system.contains("视频"))
        XCTAssertTrue(AsdExplanationPrompts.system.contains("音频"))
        XCTAssertFalse(AsdExplanationPrompts.system.contains("只返回 B01 到 B09 的 9 位二进制标签码"))
        XCTAssertFalse(AsdExplanationPrompts.system.contains("诊断结果"))
    }

    func testExplanationUserPromptDoesNotAskForReclassification() {
        XCTAssertTrue(AsdExplanationPrompts.userInstruction.contains("同一段视频"))
        XCTAssertTrue(AsdExplanationPrompts.userInstruction.contains("不要重新输出 9 位二进制码"))
        XCTAssertTrue(AsdExplanationPrompts.userInstruction.contains("不要重新分类"))
    }

    func testAssistantResultContextIncludesCodeLabelsAndB10() throws {
        let report = try XCTUnwrap(AsdBehaviorParser.parse("100000001"))
        let context = AsdExplanationPrompts.assistantResultContext(report: report)

        XCTAssertTrue(context.contains("9-bit code: 100000001"))
        XCTAssertTrue(context.contains("B01 缺乏或回避眼神接触: true"))
        XCTAssertTrue(context.contains("B09 上肢刻板动作: true"))
        XCTAssertTrue(context.contains("B10 背景（无明显目标行为）: false"))
        XCTAssertFalse(context.contains("诊断结果"))
    }
}
