import AVFoundation
import GlimmerCore
import SwiftUI

struct ReportHeaderView: View {
    let report: AsdBehaviorReport
    let timestampText: String
    let videoDurationText: String
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            conclusionCard
            videoRow
        }
    }

    private var conclusionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("报告结论")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ASDTheme.ink)

            Text(report.conclusionText)
                .font(.system(size: 17))
                .lineSpacing(6)
                .foregroundStyle(ASDTheme.ink.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.horizontal, -16)
                .padding(.top, 4)

            Text("本工具仅作早期信号提示，不构成诊断")
                .font(.system(size: 12))
                .foregroundStyle(ASDTheme.subtle)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(EdgeInsets(top: 22, leading: 20, bottom: 10, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ASDTheme.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white, lineWidth: 1)
        )
    }

    private var videoRow: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(ASDTheme.ink, in: Circle())

                Text("\(timestampText) 视频")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ASDTheme.ink)
                    .lineLimit(1)

                Spacer()

                Text(videoDurationText)
                    .font(.system(size: 14))
                    .foregroundStyle(ASDTheme.subtle)
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}
