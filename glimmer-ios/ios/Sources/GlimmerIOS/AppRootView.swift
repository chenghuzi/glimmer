import SwiftUI
import OSLog
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// App flow coordinator: splash → model download gate → main flow.
public struct AppRootView: View {
    public init() {}

    private static let logger = Logger(subsystem: "cn.enactflow.glimmer", category: "ModelDownload")

    private enum Phase { case splash, selectRegion, loading, main, needFullInstall }
    @State private var phase: Phase = .splash
    @State private var downloader = ModelDownloadManager()
    @State private var regionSelectionMessage: String?
    // macOS：把自带模型从 bundle 播种到 Application Support 时的进度/标记
    @State private var preparingFromBundle = false
    @State private var prepareProgress: CGFloat = 0

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
                // macOS 播种时复用同一个 loading 屏，进度来自 prepareProgress、文案换成「准备本地模型」；
                // 其它情况(iOS 下载 / macOS 下载兜底)用 downloader.progress + 默认下载文案。
                ModelLoadingView(
                    progress: preparingFromBundle ? prepareProgress : downloader.progress,
                    title: preparingFromBundle ? "首次启动，正在准备本地模型…" : nil
                )
                .transition(.opacity)
            case .main:
                MainFlow()
                    .transition(.opacity)
            case .needFullInstall:
                NeedFullInstallView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: phase)
        .keepScreenAwake(phase == .loading)
        .task {
            try? await Task.sleep(for: .seconds(1.6))

#if os(macOS)
            // 带模型首发版：把 bundle 内模型播种到 Application Support（一次），
            // 之后“不带模型的更新版”直接复用，无需重发 6GB / 无需下载。
            if ModelCatalog.hasBundledModels && !downloader.hasTrustedModels {
                preparingFromBundle = true
                phase = .loading
                await seedBundledModels()
                preparingFromBundle = false
            }

            // Lite 更新版（不带模型）若本机没有已播种的模型 → 不走下载，
            // 提示用户先装一次"完整安装包"（首发版会一次性把模型放好）。
            if !ModelCatalog.hasBundledModels && !downloader.hasTrustedModels {
                phase = .needFullInstall
                return
            }
#endif

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
                // 把真实失败原因透出来（之前只显示笼统文案，下载错误被吞掉，无法定位）
                let reason: String
                if case .failed(let detail) = downloader.phase {
                    reason = detail
                } else {
                    reason = "未知原因"
                }
                Self.logger.error("model download failed [\(region.rawValue, privacy: .public)]: \(reason, privacy: .public)")
                regionSelectionMessage = "下载未完成：\(reason)"
                phase = .selectRegion
            }
        }
    }

#if os(macOS)
    /// 在后台线程把 bundle 内模型拷到 Application Support，进度回主线程刷新。
    private func seedBundledModels() async {
        await Task.detached(priority: .userInitiated) {
            try? ModelCatalog.seedBundledModelsIfNeeded { p in
                Task { @MainActor in prepareProgress = CGFloat(p) }
            }
        }.value
    }
#endif
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

#if os(iOS)
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
#endif

#if os(macOS)
    /// macOS：把用户通过 fileImporter 选的(可能是安全作用域)视频拷到临时目录再用。
    private static func importPickedVideo(_ url: URL) -> URL? {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
#endif

    var body: some View {
        ZStack {
            switch activeTab {
            case .analyze:
                HomeView(
                    onStart: {
#if os(iOS)
                        showSourceSheet = true
#else
                        showLibrary = true   // macOS 直接弹文件选择
#endif
                    },
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
#if os(iOS)
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
#else
        // macOS：用系统文件选择器选视频，分析流程用 sheet 呈现。
        .fileImporter(
            isPresented: $showLibrary,
            allowedContentTypes: [.movie, .video],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result,
                  let picked = urls.first,
                  let local = Self.importPickedVideo(picked) else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                analysisURL = IdentifiableURL(url: local)
            }
        }
        .sheet(item: $analysisURL) { item in
            AnalysisFlowView(videoURL: item.url, reportStore: reportStore)
                .frame(minWidth: 430, minHeight: 760)
        }
#endif
    }
}
