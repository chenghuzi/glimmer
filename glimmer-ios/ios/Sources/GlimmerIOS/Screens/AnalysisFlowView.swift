import SwiftUI

/// 视频选好后的分析流程：预处理 → 流式推理（SSE） → 报告。
/// 走真实 ScreeningService.analyzeStream，AnalyzingView 订阅 service.output 增量重渲染。
struct AnalysisFlowView: View {
    let videoURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var service = ScreeningService()
    @State private var started = false
    @State private var doneAt: Date?

    /// 当前时间戳标签（mock 用 now；真实可挂到视频元数据）
    private let timestamp: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }()

    var body: some View {
        ZStack {
            if doneAt == nil {
                AnalyzingView(
                    timestamp: timestamp,
                    partialCode: service.output,
                    onBack: { dismiss() }
                )
            } else {
                // 完成后展示报告（旧 ReportView 解析 JSON 渲染勾选清单；视觉壳后续接散文版）
                ReportPlaceholder(
                    timestamp: timestamp,
                    raw: service.output,
                    onBack: { dismiss() }
                )
            }
        }
        .task {
            guard !started else { return }
            started = true
            await run()
        }
    }

    private func run() async {
        let media = await VideoAudioPreprocessor.prepare(videoURL: videoURL)
        guard !media.frameURLs.isEmpty else {
            service.output = "无法从视频中提取画面，请换一段视频重试。"
            return
        }
        do {
            try await service.analyzeStream(
                frameURLs: media.frameURLs,
                audioURL: media.audioURL,
                instruction: ScreeningService.userInstruction
            )
            doneAt = Date()
        } catch {
            service.output = "出错：\(error.localizedDescription)"
        }
    }
}

/// 简易报告占位：屏7/8 视觉壳后续替换。先复用旧 ReportView 把 JSON 渲染出来。
private struct ReportPlaceholder: View {
    var timestamp: String
    var raw: String
    var onBack: () -> Void

    var body: some View {
        FigmaCanvas(background: Color(hex: 0xF2F2EC)) {
            ScrollView {
                ReportView(raw: raw)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
            }
            .figmaFrame(x: 0, y: 120, w: 375, h: 540, align: .top)

            GlimmerNavBar(title: "\(timestamp) 分析报告", onBack: onBack)
                .figmaFrame(x: 0, y: 54, w: 375, h: 54, align: .top)

            PlayerBar(title: "\(timestamp) 视频")
                .figmaFrame(x: 16, y: 670, w: 343, h: 48, align: .center)

            GlimmerTabBar(active: .report)
                .figmaFrame(x: 0, y: 726, w: 375, h: 52, align: .top)
        }
    }
}
