import Foundation

/// 模型下载管理：首启把 ModelCatalog.items 下载到本地，聚合进度驱动「加载模型页面」。
/// 占位地址下走模拟进度，方便联调 UI；配置真实地址后即为真实 URLSession 下载。
@MainActor
@Observable
final class ModelDownloadManager {
    enum Phase: Equatable { case idle, downloading, ready, failed(String) }

    var progress: CGFloat = 0          // 0...1 聚合进度
    var statusText: String = "本地分析模型准备中，请稍候…"
    var phase: Phase = .idle

    var isReady: Bool { phase == .ready }

    func start() async {
        guard phase == .idle else { return }

        // 已就绪（下载过 / 随包）则直接完成
        if ModelCatalog.items.allSatisfy({ ModelCatalog.isDownloaded($0) || bundled($0) }) {
            progress = 1; statusText = "模型已就绪"; phase = .ready
            return
        }

        phase = .downloading
        try? FileManager.default.createDirectory(
            at: ModelCatalog.directory, withIntermediateDirectories: true)

        if ModelCatalog.usesPlaceholderURLs {
            await simulate()
            return
        }

        do {
            try await downloadAll()
            progress = 1; statusText = "模型已就绪"; phase = .ready
        } catch {
            statusText = "模型下载失败，请检查网络后重试"
            phase = .failed(error.localizedDescription)
        }
    }

    private func bundled(_ item: ModelCatalog.Item) -> Bool {
        Bundle.main.url(forResource: item.resource, withExtension: "gguf") != nil
    }

    // MARK: - 真实下载（按内容长度加权聚合进度）

    private func downloadAll() async throws {
        let missing = ModelCatalog.items.filter { !ModelCatalog.isDownloaded($0) && !bundled($0) }
        let total = missing.count
        for (idx, item) in missing.enumerated() {
            statusText = "正在下载模型 (\(idx + 1)/\(total))…"
            try await download(item, base: CGFloat(idx) / CGFloat(total),
                               span: 1.0 / CGFloat(total))
        }
    }

    private func download(_ item: ModelCatalog.Item, base: CGFloat, span: CGFloat) async throws {
        // TODO: 接入真实 CDN 后可改用 URLSessionDownloadDelegate 上报细粒度进度。
        // 现按文件粒度推进（多 GB 文件按字节累加会过慢）。
        let (tempURL, _) = try await URLSession.shared.download(from: item.remoteURL)
        let dest = ModelCatalog.localURL(item)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        progress = base + span
    }

    // MARK: - 占位模拟（无真实地址时演示 UI）

    private func simulate() async {
        statusText = "本地分析模型准备中，请稍候…"
        let steps = 40
        for i in 1...steps {
            try? await Task.sleep(for: .milliseconds(60))
            progress = CGFloat(i) / CGFloat(steps)
        }
        statusText = "模型已就绪"
        phase = .ready
    }
}
