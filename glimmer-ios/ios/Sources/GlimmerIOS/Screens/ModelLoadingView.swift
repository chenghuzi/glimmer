import SwiftUI

/// 屏2 模型加载 — Figma 66:484 「加载模型页面」
///
/// 自适应布局：字标居中；进度条用 GeometryReader 撑到容器宽（最大 300），
/// 星星滑块随进度滑动；状态文案在条下方；隐私脚注贴底。
struct ModelLoadingView: View {
    /// 进度 0...1（mock 默认 Figma 的 132/300；真实流程由 ModelDownloadManager 驱动）
    var progress: CGFloat = 132.0 / 300.0
    var statusText: String = "本地分析模型准备中，请稍候…"

    var body: some View {
        ZStack {
            GTheme.splashBg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Glimmer 字标（66:494）
                bundleImage("glimmer_wordmark")
                    .resizable().scaledToFit()
                    .frame(width: 268)

                // 进度条（66:486/487/488）
                progressBar
                    .frame(maxWidth: 300)
                    .padding(.top, 44)

                // 主提示（66:491）
                Text(statusText)
                    .font(.system(size: 14))
                    .foregroundStyle(GTheme.ink)
                    .padding(.top, 22)

                Spacer()

                // 隐私脚注（66:492）
                Text("微光重视您的隐私保护\n所有分析将在您的设备本地完成")
                    .font(.system(size: 12))
                    .lineSpacing(12 * 0.6)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(GTheme.subtle)
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 24)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = max(0, min(1, progress))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(hex: 0xAEB0B2, alpha: 0.34))
                    .frame(height: 5)
                Capsule()
                    .fill(Color(hex: 0xF8C304))
                    .frame(width: w * p, height: 5)
                bundleImage("star_knob")
                    .resizable().scaledToFit()
                    .frame(width: 44, height: 44)
                    .offset(x: w * p - 22)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 44)
    }
}
