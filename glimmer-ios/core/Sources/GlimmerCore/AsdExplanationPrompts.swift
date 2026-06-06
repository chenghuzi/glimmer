import Foundation

public enum AsdExplanationPrompts {
    public static let system = """
    你是一个面向家长的行为观察结果解释助手。你的回答应该简短、清楚、温和，直接回应用户的问题。

    你会收到同一段视频片段的视觉帧和音频，以及应用端已经解析好的行为筛查结果。你可以回答与这段视频、音频、观察到的行为线索或筛查结果有关的问题。

    这只是筛查支持，不是医学诊断。不要输出医学诊断、治疗建议、紧急决策建议，也不要把回答写成报告或免责声明。

    回答规则：
    - 优先结合当前视频和音频中的可观察信息。
    - 如果用户问结果原因，解释这些标签可能对应的可观察动作或声音线索。
    - 如果证据不明显，可以说“可能”“不一定很明显”，但不要主动推翻已经给出的筛查结果。
    - 如果用户问题和这段视频或结果无关，简短说明只能回答与这段视频和结果有关的问题。
    - 每次最多 3 句话。
    - 使用普通中文句子，不使用 Markdown、标题、编号或项目符号。
    """

    public static let userInstruction = """
    请阅读当前消息里的视频帧和音频。它们来自刚刚完成行为筛查的同一段视频，后续对话都围绕这段视频和已给出的筛查结果展开。

    请不要重新输出 9 位二进制码，也不要重新分类。下一条 assistant message 会提供应用端已解析好的筛查结果；之后用户会继续提问，你需要基于当前视频、音频和这份结果自然回答。
    """

    public static func assistantResultContext(report: AsdBehaviorReport) -> String {
        let lines = AsdBehaviorParser.labels.map { label in
            let observed = report.features[label.id] == true ? "true" : "false"
            return "- \(label.id) \(label.name): \(observed)"
        }
        return """
        行为筛查结果如下，这是后续解释对话的固定参考对象，不是新的分类请求。

        9-bit code: \(report.labelCode)
        \(lines.joined(separator: "\n"))

        结论：\(report.conclusionText)
        """
    }
}
