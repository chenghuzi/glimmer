import SwiftUI

/// 屏6 分析中 — Figma 53:445
///
/// 模型按 GBNF grammar 严格吐 9 位 binary code（每个 token = 1 bit）。
/// 这里订阅 service.output（流式累加的 partial code），每出一位就把对应
/// B 标签（B01…B09）滚出到列表里：'1' = 观察到，'0' = 未观察到。
struct AnalyzingView: View {
    var timestamp: String = "2026-06-03 12:12:12"
    var partialCode: String = ""
    var onBack: () -> Void = {}

    /// 当前已揭示的行为词（按位顺序）。`observed=true` 用强调色，否则灰。
    private var revealedLines: [(name: String, observed: Bool)] {
        let names = AnalyzingView.featureNames
        let chars = Array(partialCode)
        return (0..<min(chars.count, names.count)).map { i in
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
                Text("Gramma 本地完整观察视频并分析 …")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: 0x6A685D))
            }

            // 流式行为词列表 — 显示已揭示的最近几条，带上下渐变蒙版
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    // 把最后若干条挤到底部，呈现"自下而上 SSE"效果
                    Spacer(minLength: 0)
                    ForEach(Array(revealedLines.enumerated()), id: \.offset) { _, line in
                        Text(line.name)
                            .font(.system(size: 14, weight: line.observed ? .medium : .light))
                            .foregroundStyle(line.observed ? GTheme.ink : Color(hex: 0x6A685D))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 22)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                .frame(height: 60)
                .clipped()
                .animation(.easeOut(duration: 0.25), value: revealedLines.count)

                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0xF6F6F5), location: 0),
                        .init(color: Color(hex: 0xF6F6F5, alpha: 0), location: 0.25),
                        .init(color: Color(hex: 0xF6F6F5, alpha: 0), location: 0.75),
                        .init(color: Color(hex: 0xF6F6F5), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 60)
                .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 40)
        .frame(width: 343, height: 534, alignment: .top)
        .background(Color(hex: 0xF6F6F5), in: RoundedRectangle(cornerRadius: 24))
    }

    /// B01–B09 中文名（与 GlimmerCore featureIDs 顺序一致）
    static let featureNames: [String] = [
        "缺乏或回避眼神接触",
        "攻击行为",
        "对感觉输入反应过度或不足",
        "对言语互动缺乏回应",
        "非典型语言",
        "物体排列",
        "自我击打或自伤行为",
        "自我旋转或旋转物体",
        "上肢刻板动作"
    ]
}

/// Gallery 预览容器：自动跑一段模拟的 9 位流式 code，让 AnalyzingView 看起来动起来。
struct AnalyzingDemoContainer: View {
    @State private var partial = ""
    /// 一段假的 9 位 code（mock 结果：观察到几项关注行为）
    private let demoCode = "101100010"

    var body: some View {
        AnalyzingView(partialCode: partial)
            .task {
                partial = ""
                for ch in demoCode {
                    try? await Task.sleep(for: .milliseconds(500))
                    partial.append(ch)
                }
            }
    }
}
