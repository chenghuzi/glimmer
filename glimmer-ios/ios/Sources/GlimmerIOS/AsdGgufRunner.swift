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

    /// 当前 mmproj 是否支持音频（纯视觉投影器为 false）。加载后才有效。
    var supportsAudio: Bool { nativeRunner?.supportsAudio ?? false }

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

    func beginExplanationSession(
        systemPrompt: String,
        request: AsdGgufRequest,
        assistantContext: String
    ) async throws {
        guard modelFiles != nil, let nativeRunner else {
            throw AsdGgufRunnerError.missingModel
        }
        let mediaPaths = request.mediaItems.map(\.url.path)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            inferenceQueue.async {
                do {
                    try nativeRunner.beginExplanationSession(
                        withSystemPrompt: systemPrompt,
                        userPrompt: request.prompt,
                        assistantContext: assistantContext,
                        mediaPaths: mediaPaths
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func sendExplanationMessage(_ message: String, maxOutputTokens: Int = 512) async throws -> String {
        guard modelFiles != nil, let nativeRunner else {
            throw AsdGgufRunnerError.missingModel
        }
        return try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                do {
                    let output = try nativeRunner.sendExplanationUserMessage(
                        message,
                        maxOutputTokens: maxOutputTokens
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func invalidateExplanationSession() async {
        guard let nativeRunner else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            inferenceQueue.async {
                nativeRunner.invalidateExplanationSession()
                continuation.resume()
            }
        }
    }
}
