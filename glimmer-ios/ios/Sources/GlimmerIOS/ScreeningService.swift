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

    private let modelResource = "model-Q4_K_M"
    private let mmprojResource = "mmproj-bf16"
    private let runner = AsdGgufRunner()
    private var loaded = false

    func ensureLoaded() async throws {
        if loaded { return }
        statusText = "加载模型中…"

        guard let modelURL = Bundle.main.url(forResource: modelResource, withExtension: "gguf") else {
            throw AsdGgufRunnerError.missingModel
        }
        guard let mmprojURL = Bundle.main.url(forResource: mmprojResource, withExtension: "gguf") else {
            throw AsdGgufRunnerError.missingMmproj
        }

        try await runner.load(modelFiles: AsdGgufModelFiles(modelURL: modelURL, mmprojURL: mmprojURL))
        loaded = true
        statusText = "已就绪（本地 · 看 + 听）"
    }

    static let userInstruction = AsdGgufPrompts.userInstruction

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

        let request = AsdGgufRequestBuilder.build(
            frameURLs: frameURLs,
            audioURL: audioURL,
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

    func beginExplanationChat(frameURLs: [URL], audioURL: URL?) async throws {
        guard let report else { return }
        try await ensureLoaded()

        statusText = "准备本地对话…"
        isChatReady = false
        isChatResponding = false
        chatError = nil
        chatMessages = []

        let request = AsdGgufRequestBuilder.build(
            frameURLs: frameURLs,
            audioURL: audioURL,
            userPrompt: AsdExplanationPrompts.userInstruction
        )
        try await runner.beginExplanationSession(
            systemPrompt: AsdExplanationPrompts.system,
            request: request,
            assistantContext: AsdExplanationPrompts.assistantResultContext(report: report)
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
}
