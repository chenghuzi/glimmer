import SwiftUI

/// 屏6 分析中 — Figma 53:445
///
/// 模型按 GBNF grammar 严格吐 9 位 binary code（每个 token = 1 bit）。
/// 这里订阅 service.output（流式累加的 partial code），每出一位就把对应
/// B 标签（B01…B09）滚出到列表里：'1' = 观察到，'0' = 未观察到。
/// 9 位收齐后由 app 端计算 B10（B01-B09 全 0 时为 1）并补到第 10 行。
struct AnalyzingView: View {
    var timestamp: String = "2026-06-03 12:12:12"
    var partialCode: String = ""
    var onBack: () -> Void = {}
    /// 动画 + 模型都跑完时调用一次 — 用于切到报告页。
    /// 模型完成由 outside 通过 `streamFinished=true` 通知。
    var streamFinished: Bool = false
    var onAnimationDone: () -> Void = {}

    /// UI 节奏控制：模型实际 token 速度可能很快（真机几百 ms 出完 9 位），
    /// 我们不让 UI 跟着模型走，固定 0.9s/项 揭示，这样用户能看清每条行为词。
    @State private var revealedCount: Int = 0
    /// 通过 onChange 同步 displayCode.count；.task 闭包没法直接读 prop，
    /// 因为 SwiftUI 把 prop 作为 struct 的值快照，闭包捕获的是初始值。
    @State private var targetCount: Int = 0
    private let revealInterval: Duration = .milliseconds(900)

    /// 把流式 9 位 code 扩展成 10 位（追加 app 端算出的 B10）。
    /// 不足 9 位时直接返回原 code，避免提前揭示 B10。
    private var displayCode: String {
        guard partialCode.count >= 9 else { return partialCode }
        let nine = String(partialCode.prefix(9))
        let b10: Character = nine.contains("1") ? "0" : "1"
        return nine + String(b10)
    }

    /// 当前已揭示的行为词（按位顺序）。`observed=true` 用强调色，否则灰。
    private var revealedLines: [(name: String, observed: Bool)] {
        let names = AnalyzingView.featureNames
        let chars = Array(displayCode)
        let visible = min(revealedCount, chars.count, names.count)
        return (0..<visible).map { i in
            (names[i], chars[i] == "1")
        }
    }

    var body: some View {
        FigmaCanvas(background: Color(hex: 0xF2F2EC)) {
            analysisCard
                .figmaFrame(x: 16, y: 120, w: 343, h: 534, align: .center)

            GlimmerNavBar(title: "\(timestamp) 分析报告", onBack: onBack)
                .figmaFrame(x: 0, y: 54, w: 375, h: 54, align: .top)

            PlayerBar(title: "\(timestamp) 视频")
                .figmaFrame(x: 16, y: 670, w: 343, h: 48, align: .center)

            GlimmerTabBar(active: .report)
                .figmaFrame(x: 0, y: 726, w: 375, h: 52, align: .top)
        }
    }

    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                bundleImage("icon_ai_small")
                    .resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                HStack(spacing: 0) {
                    Text("Gramma 本地完整观察视频并分析")
                    AnimatedEllipsis()
                }
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: 0x6A685D))
            }

            // 流式行为词列表 — 自动滚动到最新一行
            StreamingBehaviorList(lines: revealedLines)
                .frame(height: kListHeight)
        }
        .padding(.horizontal, 20)
        .padding(.top, 40)
        // 同步 displayCode.count → targetCount（onChange 是 prop → @State 的桥梁）
        .onChange(of: displayCode.count, initial: true) { _, newCount in
            targetCount = newCount
        }
        // UI 揭示完 10 项且模型也跑完时通知上层切到报告
        .onChange(of: revealedCount) { _, newCount in
            if newCount >= 10 && streamFinished { onAnimationDone() }
        }
        .onChange(of: streamFinished) { _, finished in
            if finished && revealedCount >= 10 { onAnimationDone() }
        }
        // 节奏推进：单个长时任务读 @State targetCount（不能直接读 prop，闭包捕获的是初始快照）
        .task {
            while !Task.isCancelled {
                if revealedCount < targetCount {
                    try? await Task.sleep(for: revealInterval)
                    if Task.isCancelled { break }
                    revealedCount = min(revealedCount + 1, targetCount)
                } else {
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        }
        .frame(width: 343, height: 534, alignment: .top)
        .background(Color(hex: 0xF6F6F5), in: RoundedRectangle(cornerRadius: 24))
    }

    private let kListHeight: CGFloat = 132

    /// B01–B10 中文名（与 [behaviorFeatures](ReportView.swift:11) 保持一致）。
    /// 模型负责 B01–B09；B10 由 app 端补：当 B01-B09 都未观察到时 B10=true。
    static let featureNames: [String] = [
        "缺乏或回避眼神接触",
        "攻击行为",
        "对感觉输入反应过度或不足",
        "对言语互动缺乏回应",
        "非典型语言",
        "物体排列",
        "自我击打或自伤行为",
        "自我旋转或旋转物体",
        "上肢刻板动作",
        "背景（无明显目标行为）"
    ]
}

// MARK: - 流式行为列表（真滚动 + 上下渐变蒙版）

private struct StreamingBehaviorList: View {
    let lines: [(name: String, observed: Bool)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line.name)
                            .font(.system(size: 14, weight: line.observed ? .medium : .light))
                            .foregroundStyle(line.observed ? GTheme.ink : Color(hex: 0x6A685D))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 22)
                            .id(idx)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    }
                    // 业界推荐的 bottom sentinel：滚动只锚到这一项，避免随内容长度反复重算
                    Color.clear
                        .frame(height: 1)
                        .id("__bottom__")
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32) // 给底部留缓冲，避开 mask 淡出区
                // 关键：把 transition 接到 count 变化上，没有这个 transition 不会播
                .animation(.easeOut(duration: 0.55), value: lines.count)
            }
            .scrollDisabled(true)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.18),
                        .init(color: .black, location: 0.82),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .onChange(of: lines.count) { _, newCount in
                guard newCount > 0 else { return }
                // interpolatingSpring 出来的缓动比 easeOut 自然，
                // mass 较高 + damping 中等 → 轻微"滑行"感而非急刹
                withAnimation(.interpolatingSpring(mass: 1.4, stiffness: 70, damping: 18)) {
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - 动态省略号（. .. ... 循环，约 0.45s/拍）

private struct AnimatedEllipsis: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.45) % 4
            // phase: 0=" ", 1=".", 2="..", 3="..."
            Text(" " + String(repeating: ".", count: phase))
                .monospacedDigit()
        }
    }
}

// MARK: - Gallery demo

/// Gallery 预览容器：模拟真模型 — 9 位 code 一次性"很快"出完（200ms/位，
/// 接近 iPhone 17 Pro 上 Gemma3n 的实际 token 速率）。UI 自己按 900ms/项
/// 节奏揭示，所以这里 sleep 多短都不影响视觉。
struct AnalyzingDemoContainer: View {
    @State private var partial = ""
    @State private var streamDone = false
    @State private var showReport = false
    /// Gallery 无模型 → 用假 chat 数据演示报告页交互。
    @State private var demoMessages: [ExplanationChatMessage] = []
    @State private var demoResponding = false
    /// 假 9 位 code（mock：观察到几项关注行为）。
    private let demoCode = "101100010"

    /// 从 demoCode 模板化结论（与真实 AsdBehaviorReport.conclusionText 同款措辞）。
    private var demoConclusion: String {
        let names = zip(AnalyzingView.featureNames, demoCode)
            .filter { $0.1 == "1" }
            .map(\.0)
        guard !names.isEmpty else { return "本次片段未观察到明显目标行为特征。" }
        return "本次片段中观察到的可关注行为特征包括：\(names.joined(separator: "、"))。这些结果只表示片段中的可观察行为线索，不构成诊断。"
    }

    var body: some View {
        ZStack {
            if showReport {
                ReportConversationView(
                    timestamp: "2026-06-03 12:12:12",
                    videoDuration: "00:23",
                    conclusion: demoConclusion,
                    messages: demoMessages,
                    isChatReady: true,
                    isResponding: demoResponding,
                    onSend: { text in demoReply(to: text) },
                    onBack: { showReport = false }
                )
            } else {
                AnalyzingView(
                    partialCode: partial,
                    streamFinished: streamDone,
                    onAnimationDone: { showReport = true }
                )
            }
        }
        .task(id: showReport) {
            guard !showReport else { return }
            partial = ""
            streamDone = false
            for ch in demoCode {
                try? await Task.sleep(for: .milliseconds(200))
                partial.append(ch)
            }
            streamDone = true
        }
    }

    /// Gallery 假回复：echo 用户问题后给一句固定演示回答。
    private func demoReply(to text: String) {
        demoMessages.append(ExplanationChatMessage(role: .user, text: text))
        demoResponding = true
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            demoResponding = false
            demoMessages.append(ExplanationChatMessage(
                role: .assistant,
                text: "视频里孩子反复把罐头叠高、排列，这类重复摆弄物品的动作是筛查里关注的线索之一。单段视频不一定很明显，建议结合更多日常场景观察。"
            ))
        }
    }
}
