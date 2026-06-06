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

    static func assembleJSON(fromCode raw: String) -> String? {
        AsdBehaviorParser.parse(raw)?.jsonString
    }
}
