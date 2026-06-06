import SwiftUI
import AVFoundation
import AVKit

struct AnalysisView: View {
    let videoURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var service = ScreeningService()
    @State private var started = false
    @State private var chatDraft = ""
    @State private var reportTimestamp = Date()
    @State private var videoDurationText = "--:--"
    @State private var showVideoPlayer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ASDTheme.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                navigationBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if service.isRunning || !started {
                            progressRow
                        }

                        if let report = service.report {
                            ReportHeaderView(
                                report: report,
                                timestampText: timestampText,
                                videoDurationText: videoDurationText,
                                onPlay: { showVideoPlayer = true }
                            )
                        } else if !service.output.isEmpty {
                            failureCard(service.output)
                        }

                        chatMessages

                        Color.clear.frame(height: 132)
                    }
                    .padding(.horizontal, 16)
                }
            }

            ExplanationChatView(
                draft: $chatDraft,
                isReady: service.isChatReady,
                isResponding: service.isChatResponding,
                onSend: { text in
                    Task { await service.sendChatMessage(text) }
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .background(
                LinearGradient(
                    colors: [ASDTheme.bg.opacity(0), ASDTheme.bg, ASDTheme.bg],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 152)
                .allowsHitTesting(false),
                alignment: .bottom
            )
        }
        .task {
            guard !started else { return }
            started = true
            await run()
        }
        .sheet(isPresented: $showVideoPlayer) {
            VideoPlayer(player: AVPlayer(url: videoURL))
                .ignoresSafeArea()
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ASDTheme.ink.opacity(0.72))
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.82), in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Text("\(timestampText) 分析报告")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ASDTheme.ink.opacity(0.88))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var progressRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(service.statusText.isEmpty ? "准备中…" : service.statusText)
                .font(.system(size: 14))
                .foregroundStyle(ASDTheme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ASDTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var chatMessages: some View {
        if !service.chatMessages.isEmpty || service.isChatResponding {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(service.chatMessages) { message in
                    chatBubble(message)
                }
                if service.isChatResponding {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在本地生成回复…")
                            .font(.system(size: 13))
                            .foregroundStyle(ASDTheme.subtle)
                    }
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chatBubble(_ message: ExplanationChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 42) }
            Text(message.text)
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(message.isError ? Color(hex: 0xB6402B) : ASDTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isUser ? ASDTheme.ink.opacity(0.08) : Color.white.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 16)
                )
            if !isUser { Spacer(minLength: 42) }
        }
    }

    private func failureCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("结果解析失败")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ASDTheme.ink)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(ASDTheme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ASDTheme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var timestampText: String {
        Self.timestampFormatter.string(from: reportTimestamp)
    }

    private func run() async {
        reportTimestamp = Date()
        let media = await VideoAudioPreprocessor.prepare(videoURL: videoURL)
        videoDurationText = Self.durationText(media.diagnostics.durationSeconds)
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
            try await service.beginExplanationChat(frameURLs: media.frameURLs, audioURL: media.audioURL)
        } catch {
            service.output = "出错：\(error.localizedDescription)"
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let rounded = Int(seconds.rounded())
        return String(format: "%02d:%02d", rounded / 60, rounded % 60)
    }
}
