import SwiftUI

struct ReportHistoryDetailView: View {
    var store: ReportConversationStore
    let recordID: UUID
    var onBack: () -> Void = {}
    var onSelectAnalyze: () -> Void = {}

    @State private var service = ScreeningService()
    @State private var startedRecordID: UUID?

    private var record: ReportConversationRecord? {
        store.record(id: recordID)
    }

    var body: some View {
        if let record, let report = record.report {
            let media = store.media(for: record)
            ReportConversationView(
                timestamp: record.timestamp,
                videoTitle: record.videoTitle,
                videoURL: media.videoURL,
                videoDuration: record.videoDuration,
                conclusion: record.conclusion,
                messages: service.chatMessages,
                nonAnimatedMessageIDs: Set(record.messages.map(\.id)),
                animateInitialContent: false,
                isChatReady: service.isChatReady,
                isResponding: service.isChatResponding,
                chatError: service.chatError,
                onSend: { text in
                    Task { await service.sendChatMessage(text) }
                },
                onRetryChat: { retryChat(record: record) },
                onBack: onBack,
                onSelectTab: { tab in
                    if tab == .analyze { onSelectAnalyze() }
                }
            )
            .task(id: record.id) {
                guard startedRecordID != record.id else { return }
                startedRecordID = record.id
                service.restore(report: report, messages: record.messages)
                await startChat(record: record)
            }
            .onChange(of: service.chatMessages) { _, messages in
                store.updateMessages(recordID: record.id, messages: messages)
            }
            .onDisappear {
                Task {
                    await service.shutdown()
                }
            }
        } else {
            missingRecordView
        }
    }

    private var missingRecordView: some View {
        ZStack {
            GTheme.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                GlimmerNavBar(title: "分析报告", onBack: onBack)
                    .padding(.top, 8)
                Spacer()
                Text("这份报告已不存在")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(GTheme.ink)
                Spacer()
                GlimmerTabBar(active: .report) { tab in
                    if tab == .analyze { onSelectAnalyze() }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// 失败先自动重试 1 次，仍失败落 chatError，由 UI 显示「重试」按钮。
    private func startChat(record: ReportConversationRecord) async {
        let media = store.media(for: record)
        guard !media.frameURLs.isEmpty else {
            // 历史记录的帧文件缺失（被清理/未拷全）→ 给出错态而非无限转圈
            service.chatError = "原始视频画面已不可用，无法重建本地对话。"
            return
        }
        let maxChatAutoRetries = 1
        var attempt = 0
        while true {
            do {
                try await service.beginExplanationChat(
                    frameURLs: media.frameURLs,
                    audioURL: media.audioURL,
                    initialMessages: record.messages
                )
                return
            } catch is CancellationError {
                return
            } catch {
                guard attempt < maxChatAutoRetries, !Task.isCancelled else {
                    service.chatError = "本地对话初始化失败：\(error.localizedDescription)"
                    return
                }
                attempt += 1
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
        }
    }

    /// 用户点「重试」：清错误态，重新初始化对话。
    private func retryChat(record: ReportConversationRecord) {
        guard !service.isChatReady else { return }
        service.chatError = nil
        Task { await startChat(record: record) }
    }
}
