import SwiftUI

struct ModelLoadingView: View {
    var progress: CGFloat = 0
    /// 非空时覆盖默认下载文案（如 macOS 从 bundle 播种模型时显示“正在准备本地模型…”）。
    var title: String? = nil

    private var message: String {
        title ?? "首次使用前，下载大模型权重中...\n下载完毕后无需联网，可离线使用"
    }
    private let foregroundNotice = "模型下载需要一些时间，请勿离开当前页面，以免任务中断重来。"

    var body: some View {
        ZStack {
            GTheme.bg.ignoresSafeArea()

            VStack(spacing: 22) {
                progressLine
                    .frame(width: 248, height: 2)

                Text(message)
                    .font(.system(size: 13, weight: .regular))
                    .lineSpacing(7)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(GTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(foregroundNotice)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(GTheme.subtle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
        }
    }

    private var progressLine: some View {
        GeometryReader { proxy in
            let clamped = max(0, min(1, progress))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(GTheme.ink.opacity(0.16))
                Rectangle()
                    .fill(GTheme.ink)
                    .frame(width: proxy.size.width * clamped)
            }
        }
    }
}
