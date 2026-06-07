import Foundation

enum ModelDownloadRegion: String, Codable, Equatable {
    case china
    case global
}

enum ModelDownloadError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case incompleteFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Model download returned an invalid response."
        case .httpStatus(let status):
            return "Model download failed with HTTP status \(status)."
        case .incompleteFile(let filename):
            return "Model download did not complete: \(filename)."
        }
    }
}

private struct ModelDownloadRegionResolver {
    private struct Cache: Codable {
        let region: ModelDownloadRegion
        let checkedAt: Date
    }

    private enum Constants {
        static let cacheKey = "GlimmerModelDownloadRegion"
        static let cacheTTL: TimeInterval = 24 * 60 * 60
        static let timeout: TimeInterval = 8
        static let endpoints = [
            URL(string: "https://api.country.is/")!,
            URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!,
            URL(string: "https://ipapi.co/country/")!
        ]
    }

    func preferredRegion() async -> ModelDownloadRegion {
        if let cached = cachedRegion(), Date().timeIntervalSince(cached.checkedAt) < Constants.cacheTTL {
            return cached.region
        }

        for endpoint in Constants.endpoints {
            if let region = await resolveRegion(from: endpoint) {
                save(region)
                return region
            }
        }

        let fallback = Locale.current.region?.identifier.uppercased() == "CN"
            ? ModelDownloadRegion.china
            : ModelDownloadRegion.global
        save(fallback)
        return fallback
    }

    private func resolveRegion(from endpoint: URL) async -> ModelDownloadRegion? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = Constants.timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Constants.timeout
        configuration.timeoutIntervalForResource = Constants.timeout

        do {
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let body = String(decoding: data, as: UTF8.self)
            return parseRegion(body)
        } catch {
            return nil
        }
    }

    private func parseRegion(_ body: String) -> ModelDownloadRegion? {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let country = object["country"] as? String {
            return region(countryCode: country)
        }

        for line in body.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count == 2 {
                return region(countryCode: value)
            }
            if value.hasPrefix("loc=") {
                return region(countryCode: String(value.dropFirst(4)))
            }
        }

        return nil
    }

    private func region(countryCode: String) -> ModelDownloadRegion {
        countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "CN"
            ? .china
            : .global
    }

    private func cachedRegion() -> Cache? {
        guard let data = UserDefaults.standard.data(forKey: Constants.cacheKey) else {
            return nil
        }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func save(_ region: ModelDownloadRegion) {
        let cache = Cache(region: region, checkedAt: Date())
        guard let data = try? JSONEncoder().encode(cache) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Constants.cacheKey)
    }
}

@MainActor
@Observable
final class ModelDownloadManager {
    enum Phase: Equatable {
        case idle
        case downloading
        case ready
        case failed(String)
    }

    var progress: CGFloat = 0
    var phase: Phase = .idle

    var isReady: Bool {
        phase == .ready
    }

    var hasTrustedModels: Bool {
        ModelCatalog.allFilesTrusted()
    }

    func start() async {
        guard phase != .downloading else {
            return
        }

        if hasTrustedModels {
            progress = 1
            phase = .ready
            return
        }

        phase = .downloading
        do {
            try FileManager.default.createDirectory(
                at: ModelCatalog.directory,
                withIntermediateDirectories: true
            )
            try await prepareModels()
            progress = 1
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func prepareModels() async throws {
        let items = ModelCatalog.items
        let totalBytes = max(items.reduce(Int64(0)) { $0 + $1.byteSize }, 1)
        var completedBytes: Int64 = 0
        let region = await ModelDownloadRegionResolver().preferredRegion()

        for item in items {
            if try await ModelCatalog.validateExistingFileIfNeeded(item) {
                completedBytes += item.byteSize
                updateProgress(completedBytes: completedBytes, totalBytes: totalBytes)
                continue
            }

            ModelCatalog.removeLocalFile(item)
            try await downloadAndInstall(
                item: item,
                sourceURLs: ModelCatalog.downloadURLs(for: item, region: region),
                completedBeforeItem: completedBytes,
                totalBytes: totalBytes
            )

            completedBytes += item.byteSize
            updateProgress(completedBytes: completedBytes, totalBytes: totalBytes)
        }
    }

    private func downloadAndInstall(
        item: ModelCatalog.Item,
        sourceURLs: [URL],
        completedBeforeItem: Int64,
        totalBytes: Int64
    ) async throws {
        var lastError: Error?

        for sourceURL in sourceURLs {
            do {
                let partialBytes = ModelCatalog.validPartialSize(item)
                updateProgress(completedBytes: completedBeforeItem + partialBytes, totalBytes: totalBytes)

                if partialBytes != item.byteSize {
                    try await download(
                        item: item,
                        sourceURL: sourceURL,
                        completedBeforeItem: completedBeforeItem,
                        totalBytes: totalBytes
                    )
                }

                try ModelCatalog.installValidatedPartial(item, sourceURL: sourceURL)
                return
            } catch {
                lastError = error
                ModelCatalog.removePartialFile(item)
                updateProgress(completedBytes: completedBeforeItem, totalBytes: totalBytes)
            }
        }

        throw lastError ?? ModelDownloadError.invalidResponse
    }

    private func download(
        item: ModelCatalog.Item,
        sourceURL: URL,
        completedBeforeItem: Int64,
        totalBytes: Int64
    ) async throws {
        let downloader = ResumableFileDownloader(
            remoteURL: sourceURL,
            destinationURL: ModelCatalog.partialURL(item),
            expectedByteCount: item.byteSize
        ) { [weak self] currentBytes in
            Task { @MainActor in
                self?.updateProgress(
                    completedBytes: completedBeforeItem + currentBytes,
                    totalBytes: totalBytes
                )
            }
        }
        try await downloader.start()
    }

    private func updateProgress(completedBytes: Int64, totalBytes: Int64) {
        let value = Double(completedBytes) / Double(totalBytes)
        progress = CGFloat(max(0, min(1, value)))
    }
}

private final class ResumableFileDownloader: NSObject, URLSessionDataDelegate {
    private let remoteURL: URL
    private let destinationURL: URL
    private let expectedByteCount: Int64
    private let onProgress: @Sendable (Int64) -> Void
    private let delegateQueue: OperationQueue

    private var session: URLSession?
    private var fileHandle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingError: Error?
    private var downloadedByteCount: Int64
    private var initialByteCount: Int64

    init(
        remoteURL: URL,
        destinationURL: URL,
        expectedByteCount: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) {
        self.remoteURL = remoteURL
        self.destinationURL = destinationURL
        self.expectedByteCount = expectedByteCount
        self.onProgress = onProgress
        self.initialByteCount = ModelCatalog.fileSize(destinationURL)
        self.downloadedByteCount = self.initialByteCount

        let queue = OperationQueue()
        queue.name = "GlimmerModelDownloadDelegate"
        queue.maxConcurrentOperationCount = 1
        self.delegateQueue = queue

        super.init()
    }

    func start() async throws {
        if initialByteCount > expectedByteCount {
            try? FileManager.default.removeItem(at: destinationURL)
            initialByteCount = 0
            downloadedByteCount = 0
        }

        if initialByteCount == expectedByteCount {
            onProgress(downloadedByteCount)
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 60
            if initialByteCount > 0 {
                request.setValue("bytes=\(initialByteCount)-", forHTTPHeaderField: "Range")
            }

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60 * 12

            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            pendingError = ModelDownloadError.invalidResponse
            completionHandler(.cancel)
            return
        }

        do {
            switch http.statusCode {
            case 200:
                if initialByteCount > 0 {
                    try? FileManager.default.removeItem(at: destinationURL)
                    initialByteCount = 0
                    downloadedByteCount = 0
                }
                try openFileForWriting(append: false)
            case 206:
                try openFileForWriting(append: initialByteCount > 0)
            default:
                pendingError = ModelDownloadError.httpStatus(http.statusCode)
                completionHandler(.cancel)
                return
            }
            onProgress(downloadedByteCount)
            completionHandler(.allow)
        } catch {
            pendingError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try fileHandle?.write(contentsOf: data)
            downloadedByteCount += Int64(data.count)
            onProgress(downloadedByteCount)

            if downloadedByteCount > expectedByteCount {
                pendingError = ModelDownloadError.incompleteFile(destinationURL.lastPathComponent)
                dataTask.cancel()
            }
        } catch {
            pendingError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? fileHandle?.close()
        fileHandle = nil
        session.invalidateAndCancel()
        self.session = nil

        if let pendingError {
            continuation?.resume(throwing: pendingError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else if downloadedByteCount != expectedByteCount {
            continuation?.resume(
                throwing: ModelDownloadError.incompleteFile(destinationURL.lastPathComponent)
            )
        } else {
            continuation?.resume()
        }
        continuation = nil
    }

    private func openFileForWriting(append: Bool) throws {
        let directory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: destinationURL.path) {
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: destinationURL)
        if append {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
        }
        fileHandle = handle
    }
}
