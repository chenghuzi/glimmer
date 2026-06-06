import SwiftUI

/// 屏5 拍摄完成弹窗 — Figma 53:332 「拍摄完成」
/// 半透明遮罩 + 居中白卡 + 主按钮「视频诊断」/ 文字按钮「取消」
struct CaptureDoneDialog: View {
    var onConfirm: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        ZStack {
            // 50% 黑遮罩
            Color.black.opacity(0.5).ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            // 白卡
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("拍摄完成")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(GTheme.ink)
                    Text("确认视频拍摄完成，开始进行分析诊断")
                        .font(.system(size: 15))
                        .foregroundStyle(GTheme.subtle)
                        .multilineTextAlignment(.center)
                        .lineSpacing(15 * 0.5)
                }

                VStack(spacing: 12) {
                    Button(action: onConfirm) {
                        Text("视频诊断")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(GTheme.ink, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    Button(action: onCancel) {
                        Text("取消")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(GTheme.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .frame(width: 279)
            .background(.white, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
