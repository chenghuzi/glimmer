import SwiftUI
import AVFoundation

/// 视频选好后的分析流程：预处理 → 9 位 code 分类（真实推理）→ 报告 + 本地解释对话。
///
/// 推理用 chenghuzi 的 `ScreeningService`：
/// - `analyze` 出 9 位 code → `report`（结论模板化，零幻觉）
/// - `beginExplanationChat` 把视频帧/音频 + 结果喂进 KV-cache，开本地多轮对话
/// AnalyzingView 的逐项揭示动画是 UI 自走节奏（与模型 token 速度无关），
/// 等模型出 code（streamFinished）且动画跑完，再切报告页。
struct AnalysisFlowView: View {
    let videoURL: URL
    var reportStore: ReportConversationStore? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var service = ScreeningService()
    @State private var started = false
    @State private var showReport = false
    @State private var reportRecordID: UUID?
    @State private var videoDuration: String = "00:00"
    /// 预处理产物留存，供报告页开启解释对话时复用。
    @State private var media: PreparedGgufMedia?

    private let timestamp: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }()

    /// 模型分类完成 = report 已解析出来（或出错文案已就绪）。
    private var streamFinished: Bool { service.report != nil || !service.output.isEmpty }

    var body: some View {
        ZStack {
            if showReport {
                ReportConversationView(
                    timestamp: timestamp,
                    videoDuration: videoDuration,
                    conclusion: service.report?.conclusionText ?? service.output,
                    messages: service.chatMessages,
                    isChatReady: service.isChatReady,
                    isResponding: service.isChatResponding,
                    onSend: { text in Task { await service.sendChatMessage(text) } },
                    onBack: { dismiss() },
                    onSelectTab: { tab in
                        if tab == .analyze { dismiss() }
                    }
                )
            } else {
                AnalyzingView(
                    timestamp: timestamp,
                    partialCode: service.report?.labelCode ?? "",
                    onBack: { dismiss() },
                    streamFinished: streamFinished,
                    onAnimationDone: {
                        guard !showReport else { return }
                        persistReportIfNeeded()
                        showReport = true
                        Task { await startChat() }
                    }
                )
            }
        }
        .task {
            guard !started else { return }
            started = true
            Task { videoDuration = await Self.readDuration(videoURL) }
            await run()
        }
        .onChange(of: service.chatMessages) { _, messages in
            guard let reportRecordID else { return }
            reportStore?.updateMessages(recordID: reportRecordID, messages: messages)
        }
    }

    private func run() async {
        let prepared = await VideoAudioPreprocessor.prepare(videoURL: videoURL)
        media = prepared
        guard !prepared.frameURLs.isEmpty else {
            service.output = "无法从视频中提取画面，请换一段视频重试。"
            return
        }
        do {
            try await service.analyze(
                frameURLs: prepared.frameURLs,
                audioURL: prepared.audioURL,
                instruction: ScreeningService.userInstruction
            )
        } catch {
            service.output = "出错：\(error.localizedDescription)"
        }
    }

    /// 进报告页后，把同一段媒体 + 筛查结果灌进模型，开启本地解释对话。
    private func startChat() async {
        guard let media, service.report != nil, !service.isChatReady else { return }
        do {
            try await service.beginExplanationChat(
                frameURLs: media.frameURLs,
                audioURL: media.audioURL
            )
        } catch {
            // 对话开启失败不阻塞报告展示，仅留出错状态
            service.chatError = "本地对话初始化失败：\(error.localizedDescription)"
        }
    }

    private func persistReportIfNeeded() {
        guard reportRecordID == nil, let reportStore, let report = service.report, let media else { return }
        do {
            let record = try reportStore.createRecord(
                timestamp: timestamp,
                videoURL: videoURL,
                videoDuration: videoDuration,
                report: report,
                media: media
            )
            reportRecordID = record.id
        } catch {
            #if DEBUG
            print("Failed to persist report: \(error.localizedDescription)")
            #endif
        }
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
