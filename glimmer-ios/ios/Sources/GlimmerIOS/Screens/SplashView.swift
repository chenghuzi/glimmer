import SwiftUI

/// 屏1 启动页 — Figma 66:468 「启动App」
struct SplashView: View {
    var body: some View {
        FigmaCanvas(background: GTheme.splashBg) {
            // 底部光束（Figma 66:470，竖直翻转）
            bundleImage("light_beam")
                .resizable()
                .scaledToFill()
                .scaleEffect(y: -1)
                .figmaFrame(x: 0, y: 355, w: 375, h: 457)

            // 毛绒星星吉祥物（Figma 66:473，旋转 -4.77°）
            bundleImage("star_splash")
                .resizable()
                .scaledToFill()
                .frame(width: 202, height: 202)
                .rotationEffect(.degrees(-4.77))
                .figmaFrame(x: 83, y: 164, w: 218.09, h: 218.09)

            // Glimmer 字标（Figma 66:474）
            bundleImage("glimmer_wordmark")
                .resizable()
                .scaledToFit()
                .figmaFrame(x: 55, y: 352, w: 268, h: 73)

            // tagline（Figma 66:472）PingFang SC Regular 14 / rgba(41,41,31,0.6)
            Text("和“微光”一起关爱“星星的孩子”")
                .font(.system(size: 14))
                .tracking(0.2)
                .foregroundStyle(GTheme.subtle)
                .figmaFrame(x: 88, y: 731, w: 199, h: 22)
        }
    }
}
