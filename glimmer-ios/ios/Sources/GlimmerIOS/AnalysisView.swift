import SwiftUI
import AVFoundation

struct AnalysisView: View {
    let videoURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var service = ScreeningService()
    @State private var started = false

    var body: some View {
        ZStack(alignment: .top) {
            ASDTheme.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                // 顶部导航
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ASDTheme.ink.opacity(0.7))
                            .frame(width: 40, height: 40)
                    }
                    Spacer()
                    Text("视频分析报告").font(.system(size: 16, weight: .medium))
                    Spacer()
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.horizontal, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if service.isRunning || !started {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(service.statusText.isEmpty ? "准备中…" : service.statusText)
                                    .foregroundStyle(ASDTheme.subtle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !service.output.isEmpty {
                            if service.isRunning {
                                // 流式生成中：先显示原始文本
                                Text(service.output)
                                    .font(.system(size: 14))
                                    .foregroundStyle(ASDTheme.subtle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                    .background(ASDTheme.card, in: RoundedRectangle(cornerRadius: 16))
                            } else {
                                // 生成完成：把 JSON 美化成报告
                                ReportView(raw: service.output)
                            }
                        }

                        Text("⚠️ 本工具仅作早期信号提示，不构成诊断。分析全程在设备本地完成。")
                            .font(.system(size: 12))
                            .foregroundStyle(ASDTheme.subtle)
                    }
                    .padding(.horizontal, 16)
                }
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
            try await service.analyze(
                frameURLs: media.frameURLs,
                audioURL: media.audioURL,
                instruction: ScreeningService.userInstruction
            )
        } catch {
            service.output = "出错：\(error.localizedDescription)"
        }
    }
}
