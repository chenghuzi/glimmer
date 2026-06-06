import Foundation

enum PreprocessParityRunner {
    private static var didStart = false
    private static let environment = ProcessInfo.processInfo.environment

    static func runIfConfigured() async {
        guard !didStart else { return }
        guard let videoRootValue = environment["GLIMMER_PREPROCESS_PARITY_VIDEO_ROOT"],
              !videoRootValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        didStart = true

        let outputValue = environment["GLIMMER_PREPROCESS_PARITY_OUTPUT"] ?? "Documents/preprocess_parity_results.json"
        let videoRoot = resolveContainerURL(videoRootValue)
        let outputURL = resolveContainerURL(outputValue)

        do {
            let records = try await run(videoRoot: videoRoot)
            try write(records: records, outputURL: outputURL)
            print("GLIMMER_PREPROCESS_PARITY_RESULTS \(outputURL.path)")
        } catch {
            let failure = PreprocessParityRecord(
                sampleID: "__failure__",
                videoPath: videoRoot.path,
                frameCount: 0,
                audioPath: nil,
                diagnostics: nil,
                error: String(describing: error)
            )
            try? write(records: [failure], outputURL: outputURL)
            print("GLIMMER_PREPROCESS_PARITY_FAILURE \(String(describing: error))")
        }
    }

    private static func run(videoRoot: URL) async throws -> [PreprocessParityRecord] {
        let videos = try videoURLs(in: videoRoot)
        guard !videos.isEmpty else {
            throw PreprocessParityError.missingVideos(videoRoot.path)
        }

        var records: [PreprocessParityRecord] = []
        for videoURL in videos {
            let prepared = await VideoAudioPreprocessor.prepare(videoURL: videoURL)
            records.append(
                PreprocessParityRecord(
                    sampleID: videoURL.deletingPathExtension().lastPathComponent,
                    videoPath: videoURL.path,
                    frameCount: prepared.frameURLs.count,
                    audioPath: prepared.audioURL?.path,
                    diagnostics: prepared.diagnostics,
                    error: nil
                )
            )
        }
        return records
    }

    private static func videoURLs(in root: URL) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw PreprocessParityError.missingVideoRoot(root.path)
        }
        if !isDirectory.boolValue {
            return isVideoFile(root) ? [root] : []
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PreprocessParityError.missingVideoRoot(root.path)
        }

        var urls: [URL] = []
        for case let url as URL in enumerator where isVideoFile(url) {
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func isVideoFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v":
            return true
        default:
            return false
        }
    }

    private static func resolveContainerURL(_ value: String) -> URL {
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(value)
    }

    private static func write(records: [PreprocessParityRecord], outputURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            PreprocessParityResult(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                records: records
            )
        )
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: [.atomic])
    }
}

private struct PreprocessParityResult: Codable {
    let generatedAt: String
    let records: [PreprocessParityRecord]
}

private struct PreprocessParityRecord: Codable {
    let sampleID: String
    let videoPath: String
    let frameCount: Int
    let audioPath: String?
    let diagnostics: GgufMediaDiagnostics?
    let error: String?
}

private enum PreprocessParityError: LocalizedError {
    case missingVideoRoot(String)
    case missingVideos(String)

    var errorDescription: String? {
        switch self {
        case .missingVideoRoot(let path):
            return "Missing preprocess parity video root: \(path)"
        case .missingVideos(let path):
            return "No video files found under preprocess parity root: \(path)"
        }
    }
}
