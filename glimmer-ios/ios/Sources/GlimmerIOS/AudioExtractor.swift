import Foundation
import AVFoundation

enum AudioExtractor {
    /// 从视频里抽出音轨 → 16kHz 单声道 16-bit WAV 文件（语音模型常用格式）
    static func extractWav(from videoURL: URL) async -> URL? {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var pcm = Data()
        while let buffer = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(block)
                var chunk = Data(count: length)
                let ok = chunk.withUnsafeMutableBytes { ptr -> Bool in
                    guard let base = ptr.baseAddress else { return false }
                    return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                      destination: base) == kCMBlockBufferNoErr
                }
                if ok { pcm.append(chunk) }
            }
            CMSampleBufferInvalidate(buffer)
        }
        guard !pcm.isEmpty else { return nil }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(UUID().uuidString).wav")
        let wav = wavData(pcm: pcm, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        try? wav.write(to: out)
        return out
    }

    private static func wavData(pcm: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcm.count
        var h = Data()
        func s(_ str: String) { h.append(str.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
        s("RIFF"); u32(UInt32(36 + dataSize)); s("WAVE")
        s("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        s("data"); u32(UInt32(dataSize))
        var out = h; out.append(pcm); return out
    }
}
