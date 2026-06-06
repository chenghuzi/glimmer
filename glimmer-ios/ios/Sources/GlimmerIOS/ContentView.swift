import SwiftUI
import UIKit
import AVFoundation

struct ContentView: View {
    @State private var showSourceDialog = false
    @State private var pickerSource: UIImagePickerController.SourceType?
    @State private var analysisItem: IdentifiableURL?

    var body: some View {
        ZStack(alignment: .top) {
            ASDTheme.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // 顶部：历史按钮
                HStack {
                    historyButton
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // 标题 + 小鸭吉祥物
                ZStack(alignment: .topTrailing) {
                    bundleImage("duck")
                        .resizable().scaledToFit()
                        .frame(width: 200)
                        .offset(x: 16, y: -8)

                    Text("选择你想开始的\n筛查方式")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(ASDTheme.ink)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 60)
                }
                .padding(.horizontal, 26)

                // 视频筛查卡片（唯一入口）
                videoCard
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                Spacer(minLength: 0)

                Text("放心录制分析均在本地，不会涉及隐私泄漏")
                    .font(.system(size: 13))
                    .foregroundStyle(ASDTheme.subtle)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 16)

                tabBar
            }
        }
        .confirmationDialog("视频筛查", isPresented: $showSourceDialog, titleVisibility: .visible) {
            Button("录制视频") { startPicker(.camera) }
            Button("选择视频文件") { startPicker(.photoLibrary) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("录制或选择一段行为视频")
        }
        .fullScreenCover(item: $pickerSource) { source in
            VideoPicker(sourceType: source) { url in
                pickerSource = nil
                guard let url else { return }
                Task { await handlePicked(url) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $analysisItem) { item in
            AnalysisView(videoURL: item.url)
        }
        #if targetEnvironment(simulator)
        .task {
            guard analysisItem == nil,
                  let url = Bundle.main.url(forResource: "testclip", withExtension: "mp4") else { return }
            try? await Task.sleep(for: .milliseconds(3500))
            analysisItem = IdentifiableURL(url: url)
        }
        #endif
    }

    // MARK: - 组件

    private var historyButton: some View {
        Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(ASDTheme.ink.opacity(0.7))
            .frame(width: 40, height: 40)
            .background(Color(hex: 0xFAFAF7).opacity(0.9), in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 2)
    }

    private var videoCard: some View {
        Button { showSourceDialog = true } label: {
            ZStack(alignment: .topLeading) {
                bundleImage("phone")
                    .resizable().scaledToFit()
                    .frame(width: 150)
                    .rotationEffect(.degrees(12))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(x: 8, y: 6)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 0) {
                    Text("视频筛查分析")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(ASDTheme.ink)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(ASDTheme.ink, in: Circle())
                }
                .padding(30)
            }
            .frame(height: 153)
            .frame(maxWidth: .infinity)
            .background(ASDTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    private var tabBar: some View {
        HStack {
            tabItem(icon: "sparkles", label: "分析", active: true)
            tabItem(icon: "doc.text", label: "报告", active: false)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func tabItem(icon: String, label: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 22))
            Text(label).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(ASDTheme.ink.opacity(active ? 0.85 : 0.5))
        .frame(maxWidth: .infinity)
    }

    // MARK: - 逻辑

    private func startPicker(_ source: UIImagePickerController.SourceType) {
        // 模拟器/无摄像头时回退到相册
        if source == .camera, !UIImagePickerController.isSourceTypeAvailable(.camera) {
            pickerSource = .photoLibrary
        } else {
            pickerSource = source
        }
    }

    private func handlePicked(_ url: URL) async {
        // 不限制时长：模型按 min(16, ⌈时长⌉) 抽帧，长视频自动封顶 16 帧
        // 等选择器关闭动画结束，避免两个 cover 同时弹出导致白屏
        try? await Task.sleep(for: .milliseconds(450))
        analysisItem = IdentifiableURL(url: url)
    }
}

extension UIImagePickerController.SourceType: @retroactive Identifiable {
    public var id: Int { rawValue }
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
