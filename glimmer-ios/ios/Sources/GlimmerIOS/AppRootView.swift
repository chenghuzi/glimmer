import SwiftUI
import UIKit

/// App flow coordinator: splash → model download gate → main flow.
public struct AppRootView: View {
    public init() {}

    private enum Phase { case splash, selectRegion, loading, main }
    @State private var phase: Phase = .splash
    @State private var downloader = ModelDownloadManager()
    @State private var regionSelectionMessage: String?

    public var body: some View {
        ZStack {
            switch phase {
            case .splash:
                SplashView()
                    .transition(.opacity)
            case .selectRegion:
                ModelDownloadRegionSelectionView(
                    message: regionSelectionMessage,
                    onSelect: beginDownload
                )
                .transition(.opacity)
            case .loading:
                ModelLoadingView(
                    progress: downloader.progress,
                    downloadedBytes: downloader.downloadedBytes,
                    totalBytes: downloader.totalBytes
                )
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

            guard let region = ModelDownloadRegionPreference.savedRegion() else {
                regionSelectionMessage = nil
                phase = .selectRegion
                return
            }

            beginDownload(region)
        }
    }

    private func beginDownload(_ region: ModelDownloadRegion) {
        ModelDownloadRegionPreference.save(region)
        regionSelectionMessage = nil
        phase = .loading

        Task { @MainActor in
            await downloader.start(region: region)
            if downloader.isReady {
                phase = .main
            } else {
                ModelDownloadRegionPreference.clear()
                regionSelectionMessage = "下载未完成，请重新选择模型下载区域"
                phase = .selectRegion
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
    @State private var activeTab: GlimmerTab = .analyze
    @State private var selectedReportID: UUID?
    @State private var reportStore = ReportConversationStore()
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
            switch activeTab {
            case .analyze:
                HomeView(
                    onStart: { showSourceSheet = true },
                    onSelectReport: { activeTab = .report }
                )
            case .report:
                if let selectedReportID, reportStore.record(id: selectedReportID) != nil {
                    ReportHistoryDetailView(
                        store: reportStore,
                        recordID: selectedReportID,
                        onBack: { self.selectedReportID = nil },
                        onSelectAnalyze: {
                            self.selectedReportID = nil
                            activeTab = .analyze
                        }
                    )
                } else {
                    ReportListView(
                        store: reportStore,
                        onOpen: { record in selectedReportID = record.id },
                        onSelectAnalyze: { activeTab = .analyze }
                    )
                }
            }

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
        .task {
            reportStore.load()
        }
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
            AnalysisFlowView(videoURL: item.url, reportStore: reportStore)
        }
    }
}
