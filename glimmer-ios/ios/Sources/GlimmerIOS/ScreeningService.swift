import Foundation
import GlimmerCore

@MainActor
@Observable
final class ScreeningService {
    var output: String = ""
    var isRunning: Bool = false
    var statusText: String = "未加载"
    var report: AsdBehaviorReport?
    var chatMessages: [ExplanationChatMessage] = []
    var isChatReady: Bool = false
    var isChatResponding: Bool = false
    var chatError: String?

    private let runner = AsdGgufRunner()
    private var loaded = false

    func ensureLoaded() async throws {
        if loaded { return }
        statusText = "加载模型中…"

        try await runner.load(modelFiles: ModelCatalog.resolvedModelFiles())
        loaded = true
        statusText = "已就绪（本地 · 看 + 听）"
    }

    static let userInstruction = AsdGgufPrompts.userInstruction

    func restore(report: AsdBehaviorReport, messages: [ExplanationChatMessage]) {
        self.report = report
        self.output = report.jsonString
        self.chatMessages = messages
        self.isChatReady = false
        self.isChatResponding = false
        self.chatError = nil
    }

    func analyze(frameURLs: [URL], audioURL: URL?, instruction: String) async throws {
        try await ensureLoaded()

        isRunning = true
        output = ""
        report = nil
        chatMessages = []
        isChatReady = false
        isChatResponding = false
        chatError = nil
        await runner.invalidateExplanationSession()
        defer { isRunning = false }

        // 纯视觉投影器不支持音频 → 跳过音频，避免 marker 数与媒体数不匹配
        let request = AsdGgufRequestBuilder.build(
            frameURLs: frameURLs,
            audioURL: runner.supportsAudio ? audioURL : nil,
            userPrompt: instruction
        )
        let code = try await runner.generate(systemPrompt: AsdGgufPrompts.system, request: request)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = AsdBehaviorParser.parse(code) {
            report = parsed
            output = parsed.jsonString
        } else {
            output = code
        }
    }

    func beginExplanationChat(
        frameURLs: [URL],
        audioURL: URL?,
        initialMessages: [ExplanationChatMessage] = []
    ) async throws {
        guard let report else { return }
        try await ensureLoaded()

        statusText = "准备本地对话…"
        isChatReady = false
        isChatResponding = false
        chatError = nil
        chatMessages = initialMessages

        let request = AsdGgufRequestBuilder.build(
            frameURLs: frameURLs,
            audioURL: runner.supportsAudio ? audioURL : nil,
            userPrompt: AsdExplanationPrompts.userInstruction
        )
        try await runner.beginExplanationSession(
            systemPrompt: AsdExplanationPrompts.system,
            request: request,
            assistantContext: assistantContext(report: report, previousMessages: initialMessages)
        )
        isChatReady = true
        statusText = "已就绪（本地 · 可对话）"
    }

    func sendChatMessage(_ text: String) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, isChatReady, !isChatResponding else { return }

        chatMessages.append(ExplanationChatMessage(role: .user, text: question))
        isChatResponding = true
        chatError = nil
        defer { isChatResponding = false }

        do {
            let answer = try await runner.sendExplanationMessage(question)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            chatMessages.append(
                ExplanationChatMessage(
                    role: .assistant,
                    text: answer.isEmpty ? "我暂时没有生成有效回答，请换个问法再试一次。" : answer
                )
            )
        } catch {
            let message = "对话出错：\(error.localizedDescription)"
            chatError = message
            chatMessages.append(ExplanationChatMessage(role: .assistant, text: message, isError: true))
        }
    }

    static func assembleJSON(fromCode raw: String) -> String? {
        AsdBehaviorParser.parse(raw)?.jsonString
    }

    private func assistantContext(
        report: AsdBehaviorReport,
        previousMessages: [ExplanationChatMessage]
    ) -> String {
        let baseContext = AsdExplanationPrompts.assistantResultContext(report: report)
        let transcript = previousMessages
            .filter { !$0.isError }
            .map { message in
                let role = message.role == .user ? "User" : "Assistant"
                return "\(role): \(message.text)"
            }
            .joined(separator: "\n")

        guard !transcript.isEmpty else { return baseContext }
        return """
        \(baseContext)

        Previous conversation:
        \(transcript)
        """
    }
}
