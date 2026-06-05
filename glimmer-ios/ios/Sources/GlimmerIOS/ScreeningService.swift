import Foundation
import LiteRTLM

/// 端侧筛查服务（LiteRT-LM 运行时）：看画面 + 听声音，全程本地。
@MainActor
@Observable
final class ScreeningService {
    var output: String = ""
    var isRunning: Bool = false
    var statusText: String = "未加载"

    /// 打包在 app 里的多模态模型（.litertlm，code9 微调版：只输出 B01–B09 的 9 位二进制码）
    private let modelResource = "asd-gemma4-code9"

    private var engine: Engine?

    func ensureLoaded() async throws {
        if engine != nil { return }
        statusText = "加载模型中…"

        guard let modelPath = Bundle.main.path(forResource: modelResource, ofType: "litertlm") else {
            throw NSError(domain: "Screening", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "未在 app 内找到模型文件 \(modelResource).litertlm"])
        }
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.path

        // 后端组合按优先级尝试，失败自动回退（GPU 创建失败时退到 CPU）
        #if targetEnvironment(simulator)
        let combos: [(Backend, Backend)] = [(.cpu(), .cpu())]   // 模拟器只有 CPU
        #else
        let combos: [(Backend, Backend)] = [
            (.gpu, .gpu),       // 全 GPU（最快）
            (.gpu, .cpu()),     // LLM 用 GPU，视觉/音频用 CPU
            (.cpu(), .cpu()),   // 全 CPU（保底）
        ]
        #endif

        var lastError: Error?
        for (i, combo) in combos.enumerated() {
            do {
                let config = try EngineConfig(
                    modelPath: modelPath,
                    backend: combo.0,
                    visionBackend: combo.1,   // 开视觉
                    audioBackend: nil,        // 该微调模型无音频编码器，关掉音频
                    cacheDir: cacheDir
                )
                let e = Engine(engineConfig: config)
                try await e.initialize()
                engine = e
                statusText = "已就绪（本地 · 看 + 听）"
                return
            } catch {
                lastError = error
                statusText = "后端 \(i + 1) 失败，回退中…"
            }
        }
        throw lastError ?? NSError(domain: "Screening", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "引擎创建失败（所有后端均不可用）"])
    }

    // code9 契约（虎子官方对接文档 / prompts/zh）：模型只输出 B01–B09 的 9 位二进制码，
    // 不输出 JSON、不输出 B10；JSON 与 B10 由 app 端拼装。prompt 原文不改写。
    private let systemPrompt = """
    你是一个行为筛查辅助模型，用于根据 ASD-DS 视觉片段以及任何提供的音频标注可观察到的行为特征。

    这只是筛查支持，不是医学诊断。只能依据片段中能看见或听见的行为进行判断。

    标准行为标签如下：
    - B01：缺少或回避眼神接触
    - B02：攻击性行为
    - B03：对感觉输入反应过强或过弱
    - B04：对语言互动无回应
    - B05：非典型语言
    - B06：排列物品
    - B07：自我击打或自伤行为
    - B08：自我旋转或旋转物体
    - B09：上肢刻板动作

    B10 是背景类。不要输出 B10。B10 由应用端计算：只有当 B01 到 B09 全部为 false 时，B10 才为 true。

    只返回 B01 到 B09 的 9 位二进制标签码。
    """

    static let userInstruction = """
    请检查提供的视觉片段以及任何提供的音频，判断是否观察到 B01 到 B09 的各个标准行为特征。

    请只输出一行 9 位二进制标签码。

    必须匹配这个格式：
    ^[01]{9}$

    位序如下：
    1. B01
    2. B02
    3. B03
    4. B04
    5. B05
    6. B06
    7. B07
    8. B08
    9. B09

    规则：
    - 观察到对应行为特征时，该位输出 1。
    - 未观察到对应行为特征时，该位输出 0。
    - 不要输出 B10。
    - 不要输出 JSON。
    - 不要输出标签名、空格、标点、Markdown、置信度或解释。
    - 完整回答必须正好是 9 个字符。

    示例：
    - 如果 B01 到 B09 都没有观察到，输出：
    000000000
    - 如果只观察到 B01，输出：
    100000000
    - 如果只观察到 B09，输出：
    000000001
    - 如果同时观察到 B01 和 B09，输出：
    100000001
    """

    /// 喂入：按时间顺序的多帧图像 + 文字指令。frames（chronological）→ text instruction。
    /// 模型回 9 位码；本方法把它拼成端侧 JSON（含 B10 推导）写入 output，供 ReportView 解析。
    func analyze(imageURLs: [URL], instruction: String) async throws {
        try await ensureLoaded()
        guard let engine else { return }

        isRunning = true
        output = ""
        defer { isRunning = false }

        // 确定性解码（标签预测，temperature=0 / topK=1 / topP=1）
        let sampler = try SamplerConfig(topK: 1, topP: 1.0, temperature: 0.0)
        let convConfig = ConversationConfig(
            systemMessage: Message(systemPrompt, role: .system),
            samplerConfig: sampler
        )
        // 严格契约：每段片段新建一个 conversation，无历史。
        let conversation = try await engine.createConversation(with: convConfig)

        var contents: [Content] = imageURLs.map { .imageFile($0.path) }
        contents.append(.text(instruction))
        let message = Message(contents: contents, role: .user)

        var raw = ""
        for try await chunk in conversation.sendMessageStream(message) {
            for content in chunk.contents {
                if case .text(let t) = content { raw += t }
            }
        }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        output = Self.assembleJSON(fromCode: code) ?? code   // 非法码原样透出，ReportView 会判无效
    }

    /// 9 位二进制码 → 端侧 JSON。严格 `^[01]{9}$`；B10 = (B01..B09 全 false)。非法返回 nil。
    static func assembleJSON(fromCode raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.range(of: "^[01]{9}$", options: .regularExpression) != nil else { return nil }
        let ids = ["B01","B02","B03","B04","B05","B06","B07","B08","B09"]
        let chars = Array(code)
        var anyPos = false
        var parts: [String] = []
        for (i, id) in ids.enumerated() {
            let v = chars[i] == "1"
            anyPos = anyPos || v
            parts.append("\"\(id)\":\(v ? "true" : "false")")
        }
        parts.append("\"B10\":\(anyPos ? "false" : "true")")
        let overall = anyPos ? "behavior_features_observed" : "background"
        return "{\"schema_version\":\"1.0\",\"features\":{\(parts.joined(separator: ","))},\"overall\":\"\(overall)\"}"
    }
}
