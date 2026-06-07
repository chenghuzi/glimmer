import CryptoKit
import Foundation

enum ModelCatalogError: LocalizedError {
    case missingManifest
    case invalidManifest
    case missingItem(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "ModelManifest.json is missing from the app bundle."
        case .invalidManifest:
            return "ModelManifest.json could not be decoded."
        case .missingItem(let id):
            return "Missing model manifest item: \(id)."
        case .checksumMismatch(let filename):
            return "Downloaded model checksum mismatch: \(filename)."
        }
    }
}

enum ModelCatalog {
    struct Manifest: Decodable {
        let version: Int
        let files: [Item]
    }

    struct Item: Decodable, Identifiable, Equatable {
        let id: String
        let filename: String
        let url: URL
        let chinaURL: URL?
        let byteSize: Int64
        let sha256: String

        var resource: String {
            URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        }
    }

    struct Receipt: Codable, Equatable {
        let filename: String
        let sourceURL: String
        let byteSize: Int64
        let sha256: String
    }

    static let manifest: Manifest = {
        guard let url = Bundle.main.url(forResource: "ModelManifest", withExtension: "json") else {
            assertionFailure(ModelCatalogError.missingManifest.localizedDescription)
            return Manifest(version: 0, files: [])
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            assertionFailure("\(ModelCatalogError.invalidManifest.localizedDescription): \(error)")
            return Manifest(version: 0, files: [])
        }
    }()

    static var items: [Item] {
        manifest.files
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GlimmerModels", isDirectory: true)
    }

    static func item(id: String) -> Item? {
        items.first { $0.id == id }
    }

    static func item(resource: String) -> Item? {
        items.first { $0.resource == resource }
    }

    static func localURL(_ item: Item) -> URL {
        directory.appendingPathComponent(item.filename)
    }

    static func partialURL(_ item: Item) -> URL {
        directory.appendingPathComponent(item.filename + ".part")
    }

    static func downloadURLs(for item: Item, region: ModelDownloadRegion) -> [URL] {
        switch region {
        case .china:
            return uniqueURLs([item.chinaURL, item.url])
        case .global:
            return uniqueURLs([item.url, item.chinaURL])
        }
    }

    static func receiptURL(_ item: Item) -> URL {
        directory.appendingPathComponent(item.filename + ".receipt.json")
    }

    static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    static func resolvedURL(resource: String) -> URL? {
        guard let item = item(resource: resource), hasTrustedLocalFile(item) else {
            return nil
        }
        return localURL(item)
    }

    static func resolvedModelFiles() throws -> AsdGgufModelFiles {
        guard let model = item(id: "model") else {
            throw ModelCatalogError.missingItem("model")
        }
        guard let mmproj = item(id: "mmproj") else {
            throw ModelCatalogError.missingItem("mmproj")
        }
        guard hasTrustedLocalFile(model) else {
            throw AsdGgufRunnerError.missingModel
        }
        guard hasTrustedLocalFile(mmproj) else {
            throw AsdGgufRunnerError.missingMmproj
        }
        return AsdGgufModelFiles(modelURL: localURL(model), mmprojURL: localURL(mmproj))
    }

    static func allFilesTrusted() -> Bool {
        !items.isEmpty && items.allSatisfy { hasTrustedLocalFile($0) }
    }

    static func hasTrustedLocalFile(_ item: Item) -> Bool {
        let url = localURL(item)
        let size = fileSize(url)
        guard size > 0, let receipt = readReceipt(item) else {
            return false
        }
        return receipt.filename == item.filename
            && receipt.byteSize == size
            && receipt.sha256 == item.sha256.lowercased()
    }

    static func validateExistingFileIfNeeded(_ item: Item) async throws -> Bool {
        if hasTrustedLocalFile(item) {
            return true
        }

        let url = localURL(item)
        guard fileSize(url) == item.byteSize else {
            removeReceipt(item)
            return false
        }

        let digest = try sha256Hex(of: url)
        guard digest == item.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: url)
            removeReceipt(item)
            return false
        }

        try writeReceipt(for: item, sourceURL: item.url, byteSize: item.byteSize, sha256: digest)
        return true
    }

    static func validPartialSize(_ item: Item) -> Int64 {
        let size = fileSize(partialURL(item))
        if size > item.byteSize {
            try? FileManager.default.removeItem(at: partialURL(item))
            return 0
        }
        return size
    }

    static func installValidatedPartial(_ item: Item, sourceURL: URL) throws {
        let partial = partialURL(item)
        guard fileSize(partial) == item.byteSize else {
            throw ModelDownloadError.incompleteFile(item.filename)
        }

        let digest = try sha256Hex(of: partial)
        guard digest == item.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: partial)
            throw ModelCatalogError.checksumMismatch(item.filename)
        }

        let destination = localURL(item)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        try writeReceipt(for: item, sourceURL: sourceURL, byteSize: item.byteSize, sha256: digest)
    }

    static func removeLocalFile(_ item: Item) {
        try? FileManager.default.removeItem(at: localURL(item))
        removeReceipt(item)
    }

    static func removePartialFile(_ item: Item) {
        try? FileManager.default.removeItem(at: partialURL(item))
    }

    private static func uniqueURLs(_ urls: [URL?]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls.compactMap({ $0 }) {
            let key = url.absoluteString
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(url)
        }
        return result
    }

    private static func readReceipt(_ item: Item) -> Receipt? {
        let url = receiptURL(item)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    private static func writeReceipt(for item: Item, sourceURL: URL, byteSize: Int64, sha256: String) throws {
        let receipt = Receipt(
            filename: item.filename,
            sourceURL: sourceURL.absoluteString,
            byteSize: byteSize,
            sha256: sha256.lowercased()
        )
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: receiptURL(item), options: [.atomic])
    }

    private static func removeReceipt(_ item: Item) {
        try? FileManager.default.removeItem(at: receiptURL(item))
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
