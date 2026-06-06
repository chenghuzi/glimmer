import AVFoundation
import Foundation
import GlimmerCore
import UIKit

struct PreparedGgufMedia {
    let frameURLs: [URL]
    let audioURL: URL?
}

enum VideoAudioPreprocessor {
    static func prepare(videoURL: URL) async -> PreparedGgufMedia {
        async let frames = extractFrameFiles(videoURL)
        async let audio = AudioExtractor.extractWav(from: videoURL)
        return await PreparedGgufMedia(frameURLs: frames, audioURL: audio)
    }

    static func extractFrameFiles(_ url: URL) async -> [URL] {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        guard duration > 0 else { return [] }

        let frameCount = AsdGgufContract.requestedFrameCount(durationSeconds: duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: AsdGgufContract.imageWidth, height: 10000)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var urls: [URL] = []
        for index in 0..<frameCount {
            let seconds = AsdGgufContract.sampleTime(
                frameIndex: index,
                frameCount: frameCount,
                durationSeconds: duration
            )
            guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image,
                  let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.95) else {
                continue
            }

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(String(format: "frame_%04d_%@.jpg", index, UUID().uuidString))
            try? data.write(to: outputURL)
            urls.append(outputURL)
        }
        return urls
    }
}
