import Foundation
import GlimmerCore
@preconcurrency import AsdGgufNative

struct AsdGgufModelFiles {
    let modelURL: URL
    let mmprojURL: URL
}

enum AsdGgufRunnerError: LocalizedError {
    case missingModel
    case missingMmproj
    case nativeLoadFailed
    case nativeGenerationFailed

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "Missing GGUF model file."
        case .missingMmproj:
            return "Missing GGUF multimodal projector file."
        case .nativeLoadFailed:
            return "Failed to load the GGUF native runtime."
        case .nativeGenerationFailed:
            return "Failed to generate with the GGUF native runtime."
        }
    }
}

final class AsdGgufRunner {
    private var modelFiles: AsdGgufModelFiles?
    private var nativeRunner: ASDGgufNativeRunner?
    private let inferenceQueue = DispatchQueue(label: "com.glimmer.asd.gguf.inference", qos: .userInitiated)

    func load(modelFiles: AsdGgufModelFiles) async throws {
        guard FileManager.default.fileExists(atPath: modelFiles.modelURL.path) else {
            throw AsdGgufRunnerError.missingModel
        }
        guard FileManager.default.fileExists(atPath: modelFiles.mmprojURL.path) else {
            throw AsdGgufRunnerError.missingMmproj
        }
        do {
            self.nativeRunner = try ASDGgufNativeRunner(
                modelPath: modelFiles.modelURL.path,
                mmprojPath: modelFiles.mmprojURL.path
            )
        } catch {
            throw error
        }
        self.modelFiles = modelFiles
    }

    func generate(systemPrompt: String, request: AsdGgufRequest) async throws -> String {
        guard modelFiles != nil, let nativeRunner else {
            throw AsdGgufRunnerError.missingModel
        }
        let mediaPaths = request.mediaItems.map(\.url.path)
        return try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                do {
                    let output = try nativeRunner.generate(
                        withSystemPrompt: systemPrompt,
                        userPrompt: request.prompt,
                        mediaPaths: mediaPaths
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 流式生成：每解出一个 token piece 就回调 onToken（主线程）；返回完整 output。
    func generateStream(
        systemPrompt: String,
        request: AsdGgufRequest,
        onToken: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        guard modelFiles != nil, let nativeRunner else {
            throw AsdGgufRunnerError.missingModel
        }
        let mediaPaths = request.mediaItems.map(\.url.path)
        return try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                do {
                    let output = try nativeRunner.generateStream(
                        withSystemPrompt: systemPrompt,
                        userPrompt: request.prompt,
                        mediaPaths: mediaPaths
                    ) { piece in
                        Task { @MainActor in onToken(piece) }
                    }
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
