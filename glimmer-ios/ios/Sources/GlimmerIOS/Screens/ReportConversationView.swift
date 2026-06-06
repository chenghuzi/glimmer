import SwiftUI

/// 屏7 报告结论 + 屏8 追问对话 — Figma 53:751 + 53:994。
///
/// - 结论散文按 SSE 节奏一字一字揭示（视觉壳：本地 mock 文本 + 节流；
///   真实推理接入时只需把 `fullConclusion` 换成流式累积值）。
/// - 对话区初始为空，只有用户输入会出现气泡。
/// - Player 时长由外部传入真值（AVAsset 异步读取）。
struct ReportConversationView: View {
    var timestamp: String = "2026-06-03 12:12:12"
    var videoTitle: String = "视频"
    var videoDuration: String = "00:00"
    var fullConclusion: String
    var onBack: () -> Void = {}

    // 结论 SSE 节流：30ms/字符（中文约 30 字/秒）
    @State private var revealedConclusionCount: Int = 0
    private let charInterval: Duration = .milliseconds(30)

    // 用户输入 → 对话气泡列表
    @State private var messages: [ChatMessage] = []
    @State private var draft: String = ""

    private var revealedConclusion: String {
        let chars = Array(fullConclusion)
        let n = min(revealedConclusionCount, chars.count)
        return String(chars.prefix(n))
    }

    var body: some View {
        ZStack {
            GTheme.bg.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        conclusionAndPlayer
                        ForEach(messages) { msg in
                            switch msg.role {
                            case .user:     userBubble(msg.text)
                            case .assistant: assistantText(msg.text)
                            }
                        }
                        // 给底部固定层留位 + scroll-to-bottom 锚点
                        Color.clear.frame(height: 220).id("__bottom__")
                    }
                    .padding(.top, 120)         // nav + status bar
                    .padding(.horizontal, 16)
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }

            // 顶部 nav 浮层
            VStack(spacing: 0) {
                GlimmerNavBar(title: "\(timestamp) 分析报告", onBack: onBack)
                    .padding(.top, 54)
                Spacer()
            }
            .allowsHitTesting(true)

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
        .task(id: fullConclusion) {
            // SSE 节流揭示
            revealedConclusionCount = 0
            let total = fullConclusion.count
            while revealedConclusionCount < total && !Task.isCancelled {
                try? await Task.sleep(for: charInterval)
                if Task.isCancelled { return }
                revealedConclusionCount = min(revealedConclusionCount + 1, total)
            }
        }
    }

    // MARK: - 结论卡 + Player

    private var conclusionAndPlayer: some View {
        VStack(spacing: 12) {
            conclusionCard
            PlayerBar(title: "\(timestamp) \(videoTitle)", duration: videoDuration)
        }
    }

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

            // 底部免责声明条
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

    private func assistantText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .light))
            .foregroundStyle(Color(hex: 0x1F2329))
            .lineSpacing(8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 输入

    private var chatInputBar: some View {
        HStack(spacing: 8) {
            TextField("可以和我聊聊", text: $draft, axis: .vertical)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(GTheme.ink)
                .tint(Color(hex: 0xF8C304))
                .lineLimit(1...3)
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
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1.0)
        }
        .frame(minHeight: 48)
        .background(.white.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 2)
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: trimmed))
        draft = ""
        // 真实推理接入后：在这里 spawn 一个 Task 用本地模型生成 assistant 回复，
        // 流式 append 到一个 placeholder ChatMessage(role: .assistant) 上。
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    enum Role { case user, assistant }
    let role: Role
    let text: String
}

#Preview {
    ReportConversationView(
        videoDuration: "00:23",
        fullConclusion: MockReport.sample.conclusion
    )
}
