import SwiftUI

struct ReportHistoryDetailView: View {
    var store: ReportConversationStore
    let recordID: UUID
    var onBack: () -> Void = {}
    var onSelectAnalyze: () -> Void = {}

    @State private var service = ScreeningService()
    @State private var started = false

    private var record: ReportConversationRecord? {
        store.record(id: recordID)
    }

    var body: some View {
        if let record, let report = record.report {
            ReportConversationView(
                timestamp: record.timestamp,
                videoTitle: "视频",
                videoDuration: record.videoDuration,
                conclusion: record.conclusion,
                messages: service.chatMessages,
                isChatReady: service.isChatReady,
                isResponding: service.isChatResponding,
                onSend: { text in Task { await service.sendChatMessage(text) } },
                onBack: onBack,
                onSelectTab: { tab in
                    if tab == .analyze { onSelectAnalyze() }
                }
            )
            .task(id: record.id) {
                guard !started else { return }
                started = true
                service.restore(report: report, messages: record.messages)
                await startChat(record: record)
            }
            .onChange(of: service.chatMessages) { _, messages in
                store.updateMessages(recordID: record.id, messages: messages)
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

    private func startChat(record: ReportConversationRecord) async {
        let media = store.media(for: record)
        guard !media.frameURLs.isEmpty else { return }
        do {
            try await service.beginExplanationChat(
                frameURLs: media.frameURLs,
                audioURL: media.audioURL,
                initialMessages: record.messages
            )
        } catch {
            service.chatError = "本地对话初始化失败：\(error.localizedDescription)"
        }
    }
}
