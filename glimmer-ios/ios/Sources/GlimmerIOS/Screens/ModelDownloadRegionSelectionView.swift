import SwiftUI

struct ModelDownloadRegionSelectionView: View {
    var message: String?
    var onSelect: (ModelDownloadRegion) -> Void

    var body: some View {
        ZStack {
            GTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                bundleImage("glimmer_wordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 214)

                Text("选择模型下载区域")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(GTheme.ink)
                    .padding(.top, 42)

                VStack(spacing: 14) {
                    regionButton(.china)
                    regionButton(.global)
                }
                .padding(.top, 26)

                if let message {
                    Text(message)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(GTheme.subtle)
                        .multilineTextAlignment(.center)
                        .padding(.top, 18)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
        }
    }

    private func regionButton(_ region: ModelDownloadRegion) -> some View {
        Button {
            onSelect(region)
        } label: {
            HStack {
                Text(region.title)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(GTheme.ink)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GTheme.onInk)
                    .rotationEffect(.degrees(90))
                    .frame(width: 36, height: 36)
                    .background(GTheme.ink, in: Circle())
            }
            .padding(.leading, 22)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(GTheme.white)
            .clipShape(RoundedRectangle(cornerRadius: GTheme.cardRadius))
            .contentShape(RoundedRectangle(cornerRadius: GTheme.cardRadius))
        }
        .buttonStyle(.plain)
    }
}
