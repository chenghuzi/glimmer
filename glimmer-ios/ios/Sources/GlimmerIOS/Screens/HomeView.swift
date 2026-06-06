import SwiftUI

/// 屏3 首页 — Figma 64:414 「进入App 页面」
struct HomeView: View {
    var onStart: () -> Void = {}

    var body: some View {
        FigmaCanvas(background: Color(hex: 0xF2F2EC)) {
            // 右上角探头星星（64:415）
            // get_screenshot(64:415) 已经渲染了从根到该节点的所有变换（包括首页外层），
            // 资源即为最终方向（头朝 NE、对称轴向右上倾），SwiftUI 这边不要再叠任何镜像/旋转
            bundleImage("star_peek")
                .resizable()
                .scaledToFill()
                .frame(width: 201, height: 201)
                .clipped()
                .figmaFrame(x: 187, y: 94, w: 201, h: 201, align: .center)

            // 标题（64:454）Semibold 24 — Figma 原位 y=138，与星星竖直方向呼应
            Text("选择你要开始的\n诊断方式")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(GTheme.ink)
                .lineSpacing(6)
                .figmaFrame(x: 26, y: 138, w: 220, h: 72)

            // 视频诊断卡片（64:444）
            videoCard
                .figmaFrame(x: 16, y: 236, w: 343, h: 410, align: .center)

            // 隐私文案（64:423）13 / rgba(.6)
            Text("放心录制分析均在本地，不会涉及隐私泄漏")
                .font(.system(size: 13))
                .foregroundStyle(GTheme.subtle)
                .figmaFrame(x: 64, y: 664, w: 247, h: 18, align: .center)

            // 底部 Tab（64:424）
            GlimmerTabBar(active: .analyze)
                .figmaFrame(x: 0, y: 726, w: 375, h: 52, align: .top)
        }
    }

    // MARK: - 卡片

    private var videoCard: some View {
        Button(action: onStart) {
            videoCardBody
        }
        .buttonStyle(.plain)
    }

    private var videoCardBody: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            // 上半浅蓝块（64:452）#EEF2F5
            Rectangle()
                .fill(Color(hex: 0xEEF2F5))
                .figmaFrame(x: -1, y: -1, w: 343, h: 316)

            // 手机插画（64:453）旋转 12°
            bundleImage("phone_rec")
                .resizable().scaledToFit()
                .frame(width: 277.31, height: 277.31)
                .rotationEffect(.degrees(12))
                .figmaFrame(x: 13, y: -1, w: 328.91, h: 328.91, align: .center)

            // 底部信息行（64:445）
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("视频诊断")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(GTheme.ink)
                        .lineLimit(1)
                    Text("拍摄孩子的视频，通过本地模型进行诊断")
                        .font(.system(size: 13))
                        .foregroundStyle(GTheme.subtle)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // Figma 64:450：竖直箭头，外层旋转 90° → 视觉上向右指（播放感）
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GTheme.onInk)
                    .rotationEffect(.degrees(90))
                    .frame(width: 40, height: 40)
                    .background(GTheme.ink, in: Circle())
            }
            .figmaFrame(x: 22, y: 336, w: 296, h: 50, align: .center)
        }
        .frame(width: 343, height: 410, alignment: .topLeading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
    }
}
