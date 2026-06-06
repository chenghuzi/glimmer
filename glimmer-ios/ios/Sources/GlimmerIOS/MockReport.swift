import Foundation

/// 视觉壳阶段：只放结论散文。追问对话改为用户真实输入驱动，不再 mock。
struct MockReport {
    var conclusion: String

    static let sample = MockReport(
        conclusion: """
        本次视频中观察到孩子存在间歇性回避眼神接触、对感觉输入反应略偏迟钝，\
        以及上肢出现短暂刻板动作。多次重复的"自我旋转"片段较明显。\
        建议结合日常更多场景观察并尽早预约专业评估，以便获得更准确的判断。
        """
    )
}
