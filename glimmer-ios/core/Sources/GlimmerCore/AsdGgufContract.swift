import Foundation

public enum AsdGgufContract {
    public static let promptLanguage = "zh"
    public static let contextSize = 8192
    public static let frameFPS = 1.0
    public static let maxFrames = 32
    public static let imageWidth = 512
    public static let maxAudioSeconds = 30.0
    public static let maxOutputTokens = 16
    public static let temperature = 0.0
    public static let topK = 1
    public static let topP = 1.0
    public static let mediaMarker = "<__media__>"

    public static let code9Grammar = """
    root ::= bit bit bit bit bit bit bit bit bit
    bit ::= "0" | "1"
    """

    public static func requestedFrameCount(
        durationSeconds: Double,
        fps: Double = frameFPS,
        maxFrames: Int = maxFrames
    ) -> Int {
        guard durationSeconds > 0 else { return 1 }
        return max(1, min(maxFrames, Int(ceil(durationSeconds * fps))))
    }

    public static func effectiveFrameFPS(frameCount: Int, durationSeconds: Double) -> Double {
        guard durationSeconds > 0 else {
            return Double(frameCount)
        }
        return Double(frameCount) / durationSeconds
    }

    public static func sampleTime(frameIndex: Int, frameCount: Int, durationSeconds: Double) -> Double {
        guard frameCount > 0, durationSeconds > 0 else { return 0 }
        return Double(frameIndex) * durationSeconds / Double(frameCount)
    }

    public static func audioClipDuration(durationSeconds: Double) -> Double {
        min(max(durationSeconds, 0), maxAudioSeconds)
    }

    public static func promptWithMediaMarkers(mediaCount: Int, userPrompt: String) -> String {
        guard mediaCount > 0 else { return userPrompt }
        return String(repeating: mediaMarker, count: mediaCount) + userPrompt
    }
}
