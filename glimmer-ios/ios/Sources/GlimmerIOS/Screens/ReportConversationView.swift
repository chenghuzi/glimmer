import SwiftUI

/// 屏7 报告结论 + 屏8 追问对话 — Figma 53:751 + 53:994。
///
/// 纯展示视图（dumb view）：
/// - 结论散文（来自 `report.conclusionText`，模板化、零幻觉）按 SSE 节奏逐字揭示。
/// - 对话区由外部 `messages` 驱动（chenghuzi 的本地解释对话）；初始为空，用户提问后出现。
/// - 输入框在 `isChatReady` 前禁用（模型正在把视频灌进 KV-cache）。
struct ReportConversationView: View {
    var timestamp: String = "2026-06-03 12:12:12"
    var videoTitle: String = "视频"
    var videoDuration: String = "00:00"
    var conclusion: String
    var messages: [ExplanationChatMessage] = []
    var isChatReady: Bool = false
    var isResponding: Bool = false
    var onSend: (String) -> Void = { _ in }
    var onBack: () -> Void = {}

    // 结论 SSE 节流：30ms/字符
    @State private var revealedCount: Int = 0
    private let charInterval: Duration = .milliseconds(30)
    @State private var draft: String = ""

    private var revealedConclusion: String {
        let chars = Array(conclusion)
        return String(chars.prefix(min(revealedCount, chars.count)))
    }

    private var canSend: Bool {
        isChatReady && !isResponding && !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack {
            GTheme.bg.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        conclusionCard
                        PlayerBar(title: "\(timestamp) \(videoTitle)", duration: videoDuration)
                        ForEach(messages) { msg in
                            switch msg.role {
                            case .user:      userBubble(msg.text)
                            case .assistant: assistantText(msg.text, isError: msg.isError)
                            }
                        }
                        if isResponding { typingIndicator }
                        Color.clear.frame(height: 220).id("__bottom__")
                    }
                    .padding(.top, 120)
                    .padding(.horizontal, 16)
                }
                .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: isResponding) { _, _ in scrollToBottom(proxy) }
            }

            // 顶部 nav（带不透明背景，遮住下方滚动内容，避免叠字）
            VStack(spacing: 0) {
                GlimmerNavBar(title: "\(timestamp) 分析报告", onBack: onBack)
                    .padding(.top, 54)
                    .padding(.bottom, 6)
                    .background(GTheme.bg)
                Spacer()
            }

            // 底部输入 + 提示 + Tab
            VStack(spacing: 4) {
                Spacer()
                chatInputBar
                    .padding(.horizontal, 16)
                Text("分析与对话全程在设备本地完成")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(Color(hex: 0x666664))
                GlimmerTabBar(active: .report)
            }
        }
        .ignoresSafeArea(.keyboard)
        .task(id: conclusion) {
            revealedCount = 0
            let total = conclusion.count
            while revealedCount < total && !Task.isCancelled {
                try? await Task.sleep(for: charInterval)
                if Task.isCancelled { return }
                revealedCount = min(revealedCount + 1, total)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo("__bottom__", anchor: .bottom)
        }
    }

    // MARK: - 结论卡

    private var conclusionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("报告结论")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(GTheme.ink)
                    .tracking(0.2)

                Text(revealedConclusion)
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(GTheme.ink)
                    .lineSpacing(17 * 0.6)
                    .tracking(0.17)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 19)
            .padding(.top, 19)
            .padding(.bottom, 16)

            HStack {
                Spacer()
                Text("本工具仅作早期信号提示，不构成诊断")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(Color(hex: 0x666664))
                    .tracking(0.12)
                Spacer()
            }
            .frame(height: 32)
            .background(Color(hex: 0xF2F2F2))
            .overlay(alignment: .top) {
                Rectangle().fill(Color(hex: 0xECECEC)).frame(height: 0.5)
            }
        }
        .background(Color(hex: 0xF6F6F5))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    // MARK: - 气泡

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.system(size: 16, weight: .light))
                .lineSpacing(8)
                .foregroundStyle(GTheme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(hex: 0x29291F, alpha: 0.05),
                            in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private func assistantText(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .light))
            .foregroundStyle(isError ? Color(hex: 0xC0392B) : Color(hex: 0x1F2329))
            .lineSpacing(8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var typingIndicator: some View {
        HStack(spacing: 0) {
            Text("正在思考")
            AnimatedThinkingDots()
        }
        .font(.system(size: 16, weight: .light))
        .foregroundStyle(Color(hex: 0x666664))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 输入

    private var chatInputBar: some View {
        HStack(spacing: 8) {
            TextField(isChatReady ? "可以和我聊聊" : "正在准备本地对话…", text: $draft, axis: .vertical)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(GTheme.ink)
                .tint(Color(hex: 0xF8C304))
                .lineLimit(1...3)
                .disabled(!isChatReady)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(GTheme.ink, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .disabled(!canSend)
            .opacity(canSend ? 1.0 : 0.4)
        }
        .frame(minHeight: 48)
        .background(.white.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 2)
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isChatReady, !isResponding else { return }
        onSend(trimmed)
        draft = ""
    }
}

/// 「正在思考…」循环点点点。
private struct AnimatedThinkingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.45) % 4
            Text(String(repeating: ".", count: phase)).monospacedDigit()
        }
    }
}

#Preview {
    ReportConversationView(
        videoDuration: "00:23",
        conclusion: "本次片段中观察到的可关注行为特征包括：物体排列、上肢刻板动作。这些结果只表示片段中的可观察行为线索，不构成诊断。",
        messages: [
            ExplanationChatMessage(role: .user, text: "所以小朋友现在这种行为是有一定倾向性的么？"),
            ExplanationChatMessage(role: .assistant, text: "视频里孩子反复把罐头叠高、排列，这类重复摆弄物品的动作是筛查里关注的线索之一。不过单段视频不一定很明显，建议结合更多日常场景观察。")
        ],
        isChatReady: true
    )
}
