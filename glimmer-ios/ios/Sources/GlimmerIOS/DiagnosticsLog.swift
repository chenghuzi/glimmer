import Foundation

/// 轻量文件诊断日志：追加写入 Documents/diagnostics.log，跨启动保留。
/// 用于 USB 日志流不稳时的事后取证：卡死/强杀后，最后一行即卡点。
/// 导出途径：分析页三连击卡片弹出分享；或 Mac 上
/// `devicectl device copy from --domain-type appDataContainer` 拉取。
enum DiagnosticsLog {
    private static let queue = DispatchQueue(label: "com.glimmer.diagnostics.log", qos: .utility)
    private static let maxBytes = 1_000_000

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics.log")
    }

    static func append(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        queue.async {
            let url = fileURL
            rotateIfNeeded(url)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(stamped.utf8))
            } else {
                try? Data(stamped.utf8).write(to: url)
            }
        }
    }

    /// 超过上限时滚动到 .old，最多占用约 2MB。
    private static func rotateIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue > maxBytes else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
