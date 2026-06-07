import SwiftUI

struct ModelLoadingView: View {
    var progress: CGFloat = 0

    private let message = "首次使用前，加载大模型权重中...\n加载完毕后无需联网，可离线使用"

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
