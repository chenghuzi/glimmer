import SwiftUI

/// macOS Lite 更新版在本机检测不到已播种模型时显示。
/// 不走下载兜底：让用户先装一次「完整安装包」（首发版会把模型一次性放好）。
struct NeedFullInstallView: View {
    var body: some View {
        ZStack {
            GTheme.bg.ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer(minLength: 0)

                bundleImage("glimmer_wordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 214)

                Text("需要先安装完整版")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(GTheme.ink)
                    .padding(.top, 32)

                Text("当前是更新包（不含模型权重）。\n请先安装一次完整安装包（约 6 GB），\n模型会自动放好；之后再装本更新版即可立即使用。")
                    .font(.system(size: 13, weight: .regular))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(GTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                Button {
                    #if os(macOS)
                    NSApplication.shared.terminate(nil)
                    #endif
                } label: {
                    Text("退出")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(GTheme.onInk)
                        .frame(minWidth: 120, minHeight: 38)
                        .background(GTheme.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 20)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
        }
    }
}
