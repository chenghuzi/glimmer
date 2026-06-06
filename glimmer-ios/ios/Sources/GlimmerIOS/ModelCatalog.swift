import Foundation

/// 端侧模型清单 + 下载/定位。
///
/// 设计：模型**不再随包**，首次启动在「加载模型页面」联网下载到
/// Application Support/GlimmerModels/，运行时优先用下载好的文件，
/// 找不到再回退 app bundle（兼容旧的随包方式）。
enum ModelCatalog {
    struct Item: Identifiable {
        let resource: String      // 不含扩展名，例如 "model-Q4_K_M"
        let remoteURL: URL
        var id: String { resource }
        var filename: String { resource + ".gguf" }
    }

    // TODO: 替换为真实模型下载地址（CDN / 对象存储）。当前为占位地址，
    // placeholder host 下 ModelDownloadManager 会走「模拟进度」以便联调 UI。
    static let items: [Item] = [
        Item(resource: "model-Q4_K_M",
             remoteURL: URL(string: "https://models.example.com/glimmer/model-Q4_K_M.gguf")!),
        Item(resource: "mmproj-bf16",
             remoteURL: URL(string: "https://models.example.com/glimmer/mmproj-bf16.gguf")!),
    ]

    /// 占位地址（尚未配置真实 CDN）。
    static var usesPlaceholderURLs: Bool {
        items.contains { $0.remoteURL.host?.contains("example.com") == true }
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GlimmerModels", isDirectory: true)
    }

    static func localURL(_ item: Item) -> URL {
        directory.appendingPathComponent(item.filename)
    }

    static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    static func isDownloaded(_ item: Item) -> Bool {
        fileSize(localURL(item)) > 0
    }

    /// 运行时模型路径：优先已下载，其次 app bundle。
    static func resolvedURL(resource: String, withExtension ext: String = "gguf") -> URL? {
        let local = directory.appendingPathComponent(resource + "." + ext)
        if fileSize(local) > 0 { return local }
        return Bundle.main.url(forResource: resource, withExtension: ext)
    }
}
