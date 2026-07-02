import Foundation
import GlimmerCore

@MainActor
@Observable
final class ScreeningService {
    var output: String = ""
    var isRunning: Bool = false
    var statusText: String = L10n.text(.notLoaded, language: .zh)
    var report: AsdBehaviorReport?
    /// 分类 prefill 进度（0...1）。按已求值 token 数加权，逐帧推进。
    var analysisProgress: Double = 0
    /// 预计剩余秒数。开始时用历史速率估算，跑起来后按实际速率自校准。
    var analysisRemainingSeconds: Int?
    var chatMessages: [ExplanationChatMessage] = []
    var isChatReady: Bool = false
    var isChatResponding: Bool = false
    var chatError: String?

    private let ownerID = UUID()
    private let runner = AsdGgufRunner.shared
    private var isClosed = false
    private var language: GlimmerLanguage = .zh

    func ensureLoaded(language: GlimmerLanguage) async throws {
        self.language = language
        isClosed = false
        statusText = L10n.text(.loadingModel, language: language)

        try await runner.load(modelFiles: ModelCatalog.resolvedModelFiles(), ownerID: ownerID)
        try Task.checkCancellation()
        statusText = L10n.text(.readyLocalVisionAudio, language: language)
    }

    static let userInstruction = AsdGgufPrompts.userInstruction

    func restore(report: AsdBehaviorReport, messages: [ExplanationChatMessage], language: GlimmerLanguage) {
        self.language = language
        self.report = report
        self.output = report.jsonString
        self.chatMessages = messages
        self.isChatReady = false
        self.isChatResponding = false
        self.chatError = nil
    }

    func analyze(frameURLs: [URL], audioURL: URL?, instruction: String, language: GlimmerLanguage) async throws {
        try await ensureLoaded(language: language)

        isRunning = true
        output = ""
        report = nil
        chatMessages = []
        isChatReady = false
        isChatResponding = false
        chatError = nil
        analysisProgress = 0
        analysisRemainingSeconds = Self.initialEstimateSeconds(frameCount: frameURLs.count)
        await runner.invalidateExplanationSession(ownerID: ownerID)
        defer { isRunning = false }

        let supportsAudio = await runner.supportsAudio(ownerID: ownerID)
        let request = AsdGgufRequestBuilder.build(
            frameURLs: frameURLs,
            audioURL: supportsAudio ? audioURL : nil,
            userPrompt: instruction
        )
        let generateStart = Date()
        let code = try await runner.generate(
            systemPrompt: AsdGgufPrompts.system,
            request: request,
            ownerID: ownerID,
            onPrefillProgress: { [weak self] tokensDone, tokensTotal in
                Task { @MainActor in
                    guard let self, self.isRunning, tokensTotal > 0 else { return }
                    self.analysisProgress = Double(tokensDone) / Double(tokensTotal)
                    // 跑够半秒后按实际速率自校准，覆盖初始的历史估计。
                    let elapsed = Date().timeIntervalSince(generateStart)
                    guard tokensDone > 0, elapsed > 0.5 else { return }
                    let secondsPerToken = elapsed / Double(tokensDone)
                    let remaining = Double(tokensTotal - tokensDone) * secondsPerToken + Self.decodeTailSeconds
                    self.analysisRemainingSeconds = max(0, Int(remaining.rounded()))
                }
            }
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Self.updateSecondsPerFrameEMA(
            totalSeconds: Date().timeIntervalSince(generateStart),
            frameCount: frameURLs.count
        )
        analysisProgress = 1
        analysisRemainingSeconds = 0
        try Task.checkCancellation()
        guard !isClosed else { return }
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
        try await ensureLoaded(language: language)

        statusText = L10n.text(.preparingLocalChat, language: language)
        isChatReady = false
        isChatResponding = false
        chatError = nil
        chatMessages = initialMessages

        let context = assistantContext(report: report, previousMessages: initialMessages, language: language)
        do {
            // 快路径：分析刚结束时 KV cache 里还留着本次媒体，纯文本续接，
            // 不重编码 32 帧；历史报告重开或模型已重载时走全量 prefill。
            try await runner.continueExplanationSession(
                userInstruction: AsdExplanationPrompts.continuationInstruction(language: language),
                assistantContext: context,
                ownerID: ownerID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await runner.invalidateExplanationSession(ownerID: ownerID)
            let supportsAudio = await runner.supportsAudio(ownerID: ownerID)
            let request = AsdGgufRequestBuilder.build(
                frameURLs: frameURLs,
                audioURL: supportsAudio ? audioURL : nil,
                userPrompt: AsdExplanationPrompts.userInstruction(language: language)
            )
            try await runner.beginExplanationSession(
                systemPrompt: AsdExplanationPrompts.system(language: language),
                request: request,
                assistantContext: context,
                ownerID: ownerID
            )
        }
        try Task.checkCancellation()
        guard !isClosed else { return }
        isChatReady = true
        statusText = L10n.text(.readyLocalChat, language: language)
    }

    func sendChatMessage(_ text: String, language: GlimmerLanguage? = nil) async {
        let language = language ?? self.language
        self.language = language
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, isChatReady, !isChatResponding else { return }

        chatMessages.append(ExplanationChatMessage(role: .user, text: question))
        isChatResponding = true
        chatError = nil
        defer { isChatResponding = false }

        do {
            let answer = try await runner.sendExplanationMessage(question, ownerID: ownerID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !isClosed else { return }
            chatMessages.append(
                ExplanationChatMessage(
                    role: .assistant,
                    text: answer.isEmpty ? L10n.text(.emptyAssistantReply, language: language) : answer
                )
            )
        } catch {
            let message = L10n.chatErrorMessage(detail: error.localizedDescription, language: language)
            chatError = message
            chatMessages.append(ExplanationChatMessage(role: .assistant, text: message, isError: true))
        }
    }

    func shutdown(language: GlimmerLanguage? = nil) async {
        let language = language ?? self.language
        isClosed = true
        isRunning = false
        isChatReady = false
        isChatResponding = false
        await runner.shutdown(ownerID: ownerID)
        statusText = L10n.text(.notLoaded, language: language)
    }

    static func assembleJSON(fromCode raw: String) -> String? {
        AsdBehaviorParser.parse(raw)?.jsonString
    }

    // MARK: - 分析耗时估计（跨次自学习）

    /// 解码 9 位 code 等固定尾巴的预留秒数。
    private static let decodeTailSeconds = 2.0
    private static let secondsPerFrameKey = "GlimmerAnalysisSecondsPerFrameEMA"

    /// 开始前的预估：历史「每帧秒数」EMA × 帧数。首次运行无历史返回 nil，
    /// UI 只显示进度不显示预计时间。
    static func initialEstimateSeconds(frameCount: Int) -> Int? {
        let secondsPerFrame = UserDefaults.standard.double(forKey: secondsPerFrameKey)
        guard secondsPerFrame > 0, frameCount > 0 else { return nil }
        return Int((secondsPerFrame * Double(frameCount)).rounded())
    }

    /// 完成一次分析后更新速率 EMA。帧数、画幅、设备差异都会被均值吸收。
    static func updateSecondsPerFrameEMA(totalSeconds: Double, frameCount: Int) {
        guard frameCount > 0, totalSeconds > 0 else { return }
        let sample = totalSeconds / Double(frameCount)
        let previous = UserDefaults.standard.double(forKey: secondsPerFrameKey)
        let updated = previous > 0 ? previous * 0.7 + sample * 0.3 : sample
        UserDefaults.standard.set(updated, forKey: secondsPerFrameKey)
    }

    private func assistantContext(
        report: AsdBehaviorReport,
        previousMessages: [ExplanationChatMessage],
        language: GlimmerLanguage
    ) -> String {
        let baseContext = AsdExplanationPrompts.assistantResultContext(report: report, language: language)
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
