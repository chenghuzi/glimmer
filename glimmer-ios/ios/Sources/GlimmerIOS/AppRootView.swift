import SwiftUI
import UIKit

/// App flow coordinator: splash → model download gate → main flow.
public struct AppRootView: View {
    public init() {}

    private enum Phase { case splash, loading, main }
    @State private var phase: Phase = .splash
    @State private var downloader = ModelDownloadManager()

    public var body: some View {
        ZStack {
            switch phase {
            case .splash:
                SplashView()
                    .transition(.opacity)
            case .loading:
                ModelLoadingView(progress: downloader.progress)
                    .transition(.opacity)
            case .main:
                MainFlow()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: phase)
        .task {
            try? await Task.sleep(for: .seconds(1.6))
            if downloader.hasTrustedModels {
                phase = .main
                return
            }

            phase = .loading
            await downloader.start()
            if downloader.isReady {
                phase = .main
            }
        }
    }
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 主界面的流程：HomeView →（点卡片）系统来源选择器(拍摄/相册) → 拍完确认弹窗 → AnalyzingView → ReportView
struct MainFlow: View {
    @State private var showSourceSheet = false
    @State private var showLibrary = false
    @State private var showCamera = false
    /// 视频选好后挂起，等用户确认弹窗才进分析
    @State private var pendingURL: URL?
    @State private var analysisURL: IdentifiableURL?

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        ZStack {
            HomeView(onStart: { showSourceSheet = true })

            if pendingURL != nil {
                CaptureDoneDialog(
                    onConfirm: {
                        if let url = pendingURL {
                            analysisURL = IdentifiableURL(url: url)
                        }
                        pendingURL = nil
                    },
                    onCancel: { pendingURL = nil }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: pendingURL)
        .confirmationDialog("选择视频来源", isPresented: $showSourceSheet, titleVisibility: .hidden) {
            if cameraAvailable {
                Button("拍摄视频") {
                    // 等 sheet 完全消失再弹 cover，避免 UIKit modal 冲突
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        showCamera = true
                    }
                }
            }
            Button("从相册选择") {
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    showLibrary = true
                }
            }
            Button("取消", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showLibrary) {
            VideoPicker { url in
                showLibrary = false
                guard let url else { return }
                // 从相册选的视频直接进分析，不弹"拍摄完成"
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    analysisURL = IdentifiableURL(url: url)
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraVideoPicker { url in
                showCamera = false
                guard let url else { return }
                // 拍完才走"拍摄完成"确认弹窗
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    pendingURL = url
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $analysisURL) { item in
            AnalysisFlowView(videoURL: item.url)
        }
    }
}
