import SwiftUI

/// 屏2 模型加载 — Figma 66:484 「加载模型页面」
struct ModelLoadingView: View {
    /// 进度 0...1（mock 默认 Figma 的 132/300；真实流程由 ModelDownloadManager 驱动）
    var progress: CGFloat = 132.0 / 300.0
    var statusText: String = "本地分析模型准备中，请稍候…"

    private let barX: CGFloat = 37
    private let barY: CGFloat = 394
    private let barW: CGFloat = 300

    var body: some View {
        FigmaCanvas(background: GTheme.splashBg) {
            // Glimmer 字标（66:494）
            bundleImage("glimmer_wordmark")
                .resizable().scaledToFit()
                .figmaFrame(x: 55, y: 278, w: 268, h: 73)

            // 进度条轨道（66:486）rgba(174,176,178,0.34)
            Capsule()
                .fill(Color(hex: 0xAEB0B2, alpha: 0.34))
                .figmaFrame(x: barX, y: barY, w: barW, h: 5)

            // 进度条填充（66:487）#F8C304
            Capsule()
                .fill(Color(hex: 0xF8C304))
                .figmaFrame(x: barX, y: barY, w: barW * progress, h: 5)

            // 星星滑块（66:488）跟随进度
            bundleImage("star_knob")
                .resizable().scaledToFit()
                .figmaFrame(x: barX + barW * progress - 22, y: 375, w: 44, h: 44)

            // 主提示（66:491）PingFang SC Regular 14 / #29291F
            Text(statusText)
                .font(.system(size: 14))
                .foregroundStyle(GTheme.ink)
                .figmaFrame(x: 87, y: 415, w: 200, h: 22, align: .center)

            // 隐私脚注（66:492）两行 12 / rgba(41,41,31,0.6)
            Text("微光重视您的隐私保护\n所有分析将在您的设备本地完成")
                .font(.system(size: 12))
                .lineSpacing(12 * 0.6)
                .multilineTextAlignment(.center)
                .foregroundStyle(GTheme.subtle)
                .figmaFrame(x: 103, y: 708, w: 168, h: 38, align: .center)
        }
    }
}
