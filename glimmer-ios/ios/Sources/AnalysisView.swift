import SwiftUI
import UIKit
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
        // 按训练规范抽帧（多帧分开传），喂入模型
        let frameURLs = await extractFrameFiles(videoURL)
        guard !frameURLs.isEmpty else {
            service.output = "无法从视频中提取画面，请换一段视频重试。"
            return
        }
        do {
            try await service.analyze(imageURLs: frameURLs, instruction: ScreeningService.userInstruction)
        } catch {
            service.output = "出错：\(error.localizedDescription)"
        }
    }

    /// 按训练规范抽帧：frame_count = max(1, min(16, ceil(时长)))，覆盖整段 clip，
    /// 每帧宽 512、保持宽高比、RGB，存成临时 JPEG，返回按时间顺序的文件 URL。
    private func extractFrameFiles(_ url: URL) async -> [URL] {
        let asset = AVURLAsset(url: url)
        let dur = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        guard dur > 0 else { return [] }
        let frameCount = max(1, min(16, Int(ceil(dur))))

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 512, height: 10000)   // 宽 512，高按比例（不裁剪不拉伸）
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        // 时间戳对齐本地 eval 的 ffmpeg fps 采样：effective_fps = frameCount/dur，
        // 第 i 帧 t = i/effective_fps = i*dur/frameCount（起点锚定、顺序、覆盖整段）。
        var urls: [URL] = []
        for i in 0..<frameCount {
            let t = Double(i) * dur / Double(frameCount)
            guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            else { continue }
            if let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.95) {
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent(String(format: "frame_%02d_", i) + UUID().uuidString + ".jpg")
                try? data.write(to: out)
                urls.append(out)
            }
        }
        return urls
    }
}
