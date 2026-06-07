import SwiftUI

struct ModelLoadingView: View {
    var progress: CGFloat = 0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var title: String? = nil

    private var message: String {
        title ?? "首次使用前，下载大模型权重中...\n下载完毕后无需联网，可离线使用"
    }

    private let foregroundNotice = "下载完成前请保持应用处于前台"

    private var percentText: String {
        "\(Int((max(0, min(1, progress)) * 100).rounded()))%"
    }

    private var sizeText: String? {
        guard totalBytes > 0 else { return nil }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return "\(f.string(fromByteCount: downloadedBytes)) / \(f.string(fromByteCount: totalBytes))"
    }

    var body: some View {
        ZStack {
            GTheme.bg.ignoresSafeArea()

            VStack(spacing: 22) {
                progressLine
                    .frame(width: 248, height: 2)

                // 进度条太粗看不出在动，补一行数字反馈
                VStack(spacing: 4) {
                    Text(percentText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(GTheme.ink)
                        .monospacedDigit()
                    if let sizeText {
                        Text(sizeText)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(GTheme.subtle)
                            .monospacedDigit()
                    }
                }

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
