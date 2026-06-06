import Foundation
import GlimmerCore

@MainActor
@Observable
final class ScreeningService {
    var output: String = ""
    var isRunning: Bool = false
    var statusText: String = "未加载"

    private let modelResource = "model-Q4_K_M"
    private let mmprojResource = "mmproj-bf16"
    private let runner = AsdGgufRunner()
    private var loaded = false

    func ensureLoaded() async throws {
        if loaded { return }
        statusText = "加载模型中…"

        // 优先用下载好的模型，找不到再回退 app bundle（兼容随包方式）
        guard let modelURL = ModelCatalog.resolvedURL(resource: modelResource) else {
            throw AsdGgufRunnerError.missingModel
        }
        guard let mmprojURL = ModelCatalog.resolvedURL(resource: mmprojResource) else {
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
        defer { isRunning = false }

        let request = AsdGgufRequestBuilder.build(
            frameURLs: frameURLs,
            audioURL: audioURL,
            userPrompt: instruction
        )
        let code = try await runner.generate(systemPrompt: AsdGgufPrompts.system, request: request)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        output = AsdBehaviorParser.parse(code)?.jsonString ?? code
    }

    /// 流式分析：模型按 GBNF grammar 严格输出 9 位 binary code，每解出一位（'0' 或 '1'）
    /// 就 append 到 `output`，UI 层据此增量显示对应行为词（B01…B09，'1' 表示观察到）。
    /// 完整 9 位收到后，由 AsdBehaviorParser 补齐 B10 并出 JSON。
    func analyzeStream(frameURLs: [URL], audioURL: URL?, instruction: String) async throws {
        try await ensureLoaded()

        isRunning = true
        output = ""
        defer { isRunning = false }

        let request = AsdGgufRequestBuilder.build(
            frameURLs: frameURLs,
            audioURL: audioURL,
            userPrompt: instruction
        )
        let raw = try await runner.generateStream(
            systemPrompt: AsdGgufPrompts.system,
            request: request
        ) { [weak self] piece in
            // Grammar 限定 piece 只可能是 "0" / "1"（或空），逐位累加。
            guard let self else { return }
            self.output.append(piece)
        }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        output = AsdBehaviorParser.parse(code)?.jsonString ?? code
    }

    static func assembleJSON(fromCode raw: String) -> String? {
        AsdBehaviorParser.parse(raw)?.jsonString
    }
}
