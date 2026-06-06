import SwiftUI
import AVFoundation

/// 视频选好后的分析流程：预处理 → 流式推理（SSE） → 报告。
/// 走真实 ScreeningService.analyzeStream，AnalyzingView 订阅 service.output 增量重渲染。
struct AnalysisFlowView: View {
    let videoURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var service = ScreeningService()
    @State private var started = false
    /// 模型流式完成（9 位 code 收齐）。UI 动画跑完才切到报告页。
    @State private var streamFinished = false
    @State private var showReport = false
    @State private var videoDuration: String = "00:00"

    /// 当前时间戳标签（mock 用 now；真实可挂到视频元数据）
    private let timestamp: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }()

    var body: some View {
        ZStack {
            if showReport {
                // 视觉壳阶段：固定用 mock 报告散文；对话区初始为空，由用户输入驱动
                ReportConversationView(
                    timestamp: timestamp,
                    videoDuration: videoDuration,
                    fullConclusion: MockReport.sample.conclusion,
                    onBack: { dismiss() }
                )
            } else {
                AnalyzingView(
                    timestamp: timestamp,
                    partialCode: service.output,
                    onBack: { dismiss() },
                    streamFinished: streamFinished,
                    onAnimationDone: { showReport = true }
                )
            }
        }
        .task {
            guard !started else { return }
            started = true
            // 异步读真实视频时长（与分析并行）
            Task { videoDuration = await Self.readDuration(videoURL) }
            await run()
        }
    }

    private func run() async {
        let media = await VideoAudioPreprocessor.prepare(videoURL: videoURL)
        guard !media.frameURLs.isEmpty else {
            service.output = "无法从视频中提取画面，请换一段视频重试。"
            streamFinished = true
            return
        }
        do {
            try await service.analyzeStream(
                frameURLs: media.frameURLs,
                audioURL: media.audioURL,
                instruction: ScreeningService.userInstruction
            )
        } catch {
            service.output = "出错：\(error.localizedDescription)"
        }
        streamFinished = true
    }

    /// 读视频文件真实时长（秒）→ "MM:SS"。读失败回退 "00:00"。
    private static func readDuration(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        do {
            let d = try await asset.load(.duration)
            let secs = max(0, Int(CMTimeGetSeconds(d).rounded()))
            return String(format: "%02d:%02d", secs / 60, secs % 60)
        } catch {
            return "00:00"
        }
    }
}

