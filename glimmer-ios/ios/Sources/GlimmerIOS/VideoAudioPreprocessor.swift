import AVFoundation
import CoreImage
import Foundation
import GlimmerCore
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

enum VideoAudioPreprocessor {
    static func prepare(videoURL: URL) async -> PreparedGgufMedia {
        let outputDirectory = makeOutputDirectory()
        let asset = AVURLAsset(url: videoURL)
        let assetDuration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        let duration = resolvedDuration(for: videoURL, assetDurationSeconds: assetDuration)

        async let frames = extractFrames(videoURL, durationSeconds: duration.seconds, outputDirectory: outputDirectory)
        async let audio = AudioExtractor.extractWav(
            from: videoURL,
            durationSeconds: duration.seconds,
            outputDirectory: outputDirectory
        )

        let frameResult = await frames
        let audioResult = await audio

        return PreparedGgufMedia(
            frameURLs: frameResult.frameURLs,
            audioURL: audioResult.url,
            diagnostics: GgufMediaDiagnostics(
                sourceVideoPath: videoURL.path,
                outputDirectoryPath: outputDirectory.path,
                assetDurationSeconds: assetDuration,
                durationSeconds: duration.seconds,
                durationSource: duration.source,
                requestedFrameCount: AsdGgufContract.requestedFrameCount(durationSeconds: duration.seconds),
                frameDiagnostics: frameResult.diagnostics,
                audioDiagnostics: audioResult.diagnostics
            )
        )
    }

    static func extractFrameFiles(_ url: URL) async -> [URL] {
        let asset = AVURLAsset(url: url)
        let assetDuration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        let duration = resolvedDuration(for: url, assetDurationSeconds: assetDuration)
        return await extractFrames(
            url,
            durationSeconds: duration.seconds,
            outputDirectory: makeOutputDirectory()
        ).frameURLs
    }

    private static func extractFrames(
        _ url: URL,
        durationSeconds: Double,
        outputDirectory: URL
    ) async -> FrameExtractionResult {
        let asset = AVURLAsset(url: url)
        guard durationSeconds > 0 else {
            return FrameExtractionResult(
                frameURLs: [],
                diagnostics: [
                    GgufFrameDiagnostics(
                        index: 0,
                        requestedTimeSeconds: 0,
                        actualTimeSeconds: nil,
                        sourceWidth: nil,
                        sourceHeight: nil,
                        outputWidth: nil,
                        outputHeight: nil,
                        path: nil,
                        byteCount: nil,
                        sha256: nil,
                        error: "Invalid video duration"
                    )
                ]
            )
        }

        let frameCount = AsdGgufContract.requestedFrameCount(durationSeconds: durationSeconds)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return FrameExtractionResult(
                frameURLs: [],
                diagnostics: [
                    GgufFrameDiagnostics(
                        index: 0,
                        requestedTimeSeconds: 0,
                        actualTimeSeconds: nil,
                        sourceWidth: nil,
                        sourceHeight: nil,
                        outputWidth: nil,
                        outputHeight: nil,
                        path: nil,
                        byteCount: nil,
                        sha256: nil,
                        error: "Missing video track"
                    )
                ]
            )
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            return FrameExtractionResult(
                frameURLs: [],
                diagnostics: [
                    GgufFrameDiagnostics(
                        index: 0,
                        requestedTimeSeconds: 0,
                        actualTimeSeconds: nil,
                        sourceWidth: nil,
                        sourceHeight: nil,
                        outputWidth: nil,
                        outputHeight: nil,
                        path: nil,
                        byteCount: nil,
                        sha256: nil,
                        error: "Failed to create AVAssetReader"
                    )
                ]
            )
        }

        let preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return FrameExtractionResult(
                frameURLs: [],
                diagnostics: [
                    GgufFrameDiagnostics(
                        index: 0,
                        requestedTimeSeconds: 0,
                        actualTimeSeconds: nil,
                        sourceWidth: nil,
                        sourceHeight: nil,
                        outputWidth: nil,
                        outputHeight: nil,
                        path: nil,
                        byteCount: nil,
                        sha256: nil,
                        error: "Cannot add AVAssetReaderTrackOutput"
                    )
                ]
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            return FrameExtractionResult(
                frameURLs: [],
                diagnostics: [
                    GgufFrameDiagnostics(
                        index: 0,
                        requestedTimeSeconds: 0,
                        actualTimeSeconds: nil,
                        sourceWidth: nil,
                        sourceHeight: nil,
                        outputWidth: nil,
                        outputHeight: nil,
                        path: nil,
                        byteCount: nil,
                        sha256: nil,
                        error: reader.error.map { String(describing: $0) } ?? "Failed to start video reader"
                    )
                ]
            )
        }

        let targetTimes = AsdGgufContract.sampleTimes(frameCount: frameCount, durationSeconds: durationSeconds)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ciContext = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
        ])
        var urls: [URL] = []
        var diagnostics: [GgufFrameDiagnostics] = []
        var targetIndex = 0
        // 只按时间戳选帧，延迟到命中采样点才做 CIContext 渲染 + JPEG 编码；
        // 未命中的帧只留一个 CVPixelBuffer 引用（任意时刻至多持有 2 个，
        // 池会为被持有的 buffer 另行分配，不会被解码器覆写）。
        var previousFrame: DecodedVideoFrame?
        // 同一帧可能被相邻多个采样点选中（源 fps 低于采样率、或视频尾部补帧），
        // 按时间戳缓存最近一次渲染结果，避免重复渲染。
        var renderCache: RenderedFrame?

        func renderedFrame(for frame: DecodedVideoFrame) -> RenderedFrame? {
            if let renderCache, renderCache.timeSeconds == frame.timeSeconds {
                return renderCache
            }
            guard let image = makeCGImage(
                from: frame.pixelBuffer,
                preferredTransform: preferredTransform,
                context: ciContext
            ), let rendered = renderFrameJPEG(image) else {
                return nil
            }
            let result = RenderedFrame(
                timeSeconds: frame.timeSeconds,
                data: rendered.data,
                outputWidth: rendered.width,
                outputHeight: rendered.height,
                sourceWidth: image.width,
                sourceHeight: image.height
            )
            renderCache = result
            return result
        }

        func appendFrame(_ frame: DecodedVideoFrame, requestedTimeSeconds: Double, index: Int) {
            guard let rendered = renderedFrame(for: frame) else {
                diagnostics.append(
                    GgufFrameDiagnostics(
                        index: index,
                        requestedTimeSeconds: requestedTimeSeconds,
                        actualTimeSeconds: frame.timeSeconds,
                        sourceWidth: nil,
                        sourceHeight: nil,
                        outputWidth: nil,
                        outputHeight: nil,
                        path: nil,
                        byteCount: nil,
                        sha256: nil,
                        error: "Failed to render JPEG"
                    )
                )
                return
            }

            let outputURL = outputDirectory.appendingPathComponent(String(format: "frame_%04d.jpg", index))
            do {
                try rendered.data.write(to: outputURL, options: .atomic)
            } catch {
                diagnostics.append(
                    GgufFrameDiagnostics(
                        index: index,
                        requestedTimeSeconds: requestedTimeSeconds,
                        actualTimeSeconds: frame.timeSeconds,
                        sourceWidth: rendered.sourceWidth,
                        sourceHeight: rendered.sourceHeight,
                        outputWidth: rendered.outputWidth,
                        outputHeight: rendered.outputHeight,
                        path: outputURL.path,
                        byteCount: nil,
                        sha256: nil,
                        error: String(describing: error)
                    )
                )
                return
            }

            urls.append(outputURL)
            diagnostics.append(
                GgufFrameDiagnostics(
                    index: index,
                    requestedTimeSeconds: requestedTimeSeconds,
                    actualTimeSeconds: frame.timeSeconds,
                    sourceWidth: rendered.sourceWidth,
                    sourceHeight: rendered.sourceHeight,
                    outputWidth: rendered.outputWidth,
                    outputHeight: rendered.outputHeight,
                    path: outputURL.path,
                    byteCount: rendered.data.count,
                    sha256: MediaDiagnostics.sha256Hex(data: rendered.data),
                    error: nil
                )
            )
        }

        while targetIndex < targetTimes.count, let buffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(buffer) }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(buffer)
            let timeSeconds = CMTimeGetSeconds(presentationTime)
            guard timeSeconds.isFinite,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
                continue
            }

            let currentFrame = DecodedVideoFrame(timeSeconds: timeSeconds, pixelBuffer: pixelBuffer)
            while targetIndex < targetTimes.count, timeSeconds >= targetTimes[targetIndex] {
                let targetTime = targetTimes[targetIndex]
                let chosenFrame = nearestFrame(
                    previous: previousFrame,
                    current: currentFrame,
                    targetTimeSeconds: targetTime
                )
                appendFrame(chosenFrame, requestedTimeSeconds: targetTime, index: targetIndex)
                targetIndex += 1
            }
            previousFrame = currentFrame
        }

        while targetIndex < targetTimes.count, let previousFrame {
            let targetTime = targetTimes[targetIndex]
            appendFrame(previousFrame, requestedTimeSeconds: targetTime, index: targetIndex)
            targetIndex += 1
        }

        return FrameExtractionResult(frameURLs: urls, diagnostics: diagnostics)
    }

    private static func makeOutputDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glimmer_media_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func resolvedDuration(for videoURL: URL, assetDurationSeconds: Double) -> MediaDuration {
        if let filenameDuration = AsdGgufContract.asdDSClipDurationSeconds(
            fileStem: videoURL.deletingPathExtension().lastPathComponent
        ), assetDurationSeconds <= 0 || abs(assetDurationSeconds - filenameDuration) <= 1.0 {
            return MediaDuration(seconds: filenameDuration, source: "asd_ds_filename")
        }
        return MediaDuration(seconds: assetDurationSeconds, source: "asset")
    }

    private static func renderFrameJPEG(_ image: CGImage) -> (data: Data, width: Int, height: Int)? {
        let scaled = AsdGgufContract.scaledImageSize(
            sourceWidth: image.width,
            sourceHeight: image.height
        )
#if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        let bounds = CGRect(x: 0, y: 0, width: scaled.width, height: scaled.height)
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        let renderedImage = renderer.image { context in
            UIColor.black.setFill()
            context.fill(bounds)
            context.cgContext.interpolationQuality = .high
            UIImage(cgImage: image).draw(in: bounds)
        }

        guard let data = renderedImage.jpegData(compressionQuality: 0.95) else {
            return nil
        }
        return (data, scaled.width, scaled.height)
#else
        // macOS：纯 CoreGraphics 绘制 + ImageIO 编码 JPEG（不依赖 UIKit/AppKit）。
        let width = scaled.width
        let height = scaled.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let rendered = ctx.makeImage() else { return nil }

        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, rendered, [
            kCGImageDestinationLossyCompressionQuality: 0.95
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (outData as Data, width, height)
#endif
    }

    private static func makeCGImage(
        from pixelBuffer: CVPixelBuffer,
        preferredTransform: CGAffineTransform,
        context: CIContext
    ) -> CGImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if preferredTransform != .identity {
            image = image.transformed(by: preferredTransform)
            let extent = image.extent
            image = image.transformed(
                by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
            )
        }
        return context.createCGImage(image, from: image.extent)
    }

    private static func nearestFrame(
        previous: DecodedVideoFrame?,
        current: DecodedVideoFrame,
        targetTimeSeconds: Double
    ) -> DecodedVideoFrame {
        guard let previous else { return current }
        let previousDistance = abs(previous.timeSeconds - targetTimeSeconds)
        let currentDistance = abs(current.timeSeconds - targetTimeSeconds)
        return currentDistance <= previousDistance ? current : previous
    }
}

private struct MediaDuration {
    let seconds: Double
    let source: String
}

private struct DecodedVideoFrame {
    let timeSeconds: Double
    let pixelBuffer: CVPixelBuffer
}

private struct RenderedFrame {
    let timeSeconds: Double
    let data: Data
    let outputWidth: Int
    let outputHeight: Int
    let sourceWidth: Int
    let sourceHeight: Int
}
