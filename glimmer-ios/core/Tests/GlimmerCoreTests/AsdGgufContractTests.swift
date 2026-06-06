import XCTest
@testable import GlimmerCore

final class AsdGgufContractTests: XCTestCase {
    func testGenerationConstantsMatchMacEval() {
        XCTAssertEqual(AsdGgufContract.promptLanguage, "zh")
        XCTAssertEqual(AsdGgufContract.contextSize, 8192)
        XCTAssertEqual(AsdGgufContract.frameFPS, 1.0)
        XCTAssertEqual(AsdGgufContract.maxFrames, 32)
        XCTAssertEqual(AsdGgufContract.imageWidth, 512)
        XCTAssertEqual(AsdGgufContract.maxAudioSeconds, 30.0)
        XCTAssertEqual(AsdGgufContract.maxOutputTokens, 16)
        XCTAssertEqual(AsdGgufContract.temperature, 0.0)
        XCTAssertEqual(AsdGgufContract.topK, 1)
        XCTAssertEqual(AsdGgufContract.topP, 1.0)
        XCTAssertEqual(AsdGgufContract.mediaMarker, "<__media__>")
        XCTAssertEqual(
            AsdGgufContract.code9Grammar,
            """
            root ::= bit bit bit bit bit bit bit bit bit
            bit ::= "0" | "1"
            """
        )
    }

    func testFrameCountMatchesMacEval() {
        XCTAssertEqual(AsdGgufContract.requestedFrameCount(durationSeconds: 3.0), 3)
        XCTAssertEqual(AsdGgufContract.requestedFrameCount(durationSeconds: 3.01), 4)
        XCTAssertEqual(AsdGgufContract.requestedFrameCount(durationSeconds: 50.53), 32)
        XCTAssertEqual(AsdGgufContract.requestedFrameCount(durationSeconds: 0.0), 1)
        XCTAssertEqual(AsdGgufContract.requestedFrameCount(durationSeconds: -1.0), 1)
    }

    func testSamplingScheduleMatchesMacEval() {
        XCTAssertEqual(AsdGgufContract.effectiveFrameFPS(frameCount: 3, durationSeconds: 3.0), 1.0)
        XCTAssertEqual(AsdGgufContract.sampleTime(frameIndex: 0, frameCount: 4, durationSeconds: 4.0), 0.0)
        XCTAssertEqual(AsdGgufContract.sampleTime(frameIndex: 1, frameCount: 4, durationSeconds: 4.0), 1.0)
        XCTAssertEqual(AsdGgufContract.sampleTime(frameIndex: 3, frameCount: 4, durationSeconds: 4.0), 3.0)
    }

    func testAudioDurationMatchesMacEval() {
        XCTAssertEqual(AsdGgufContract.audioClipDuration(durationSeconds: 3.0), 3.0)
        XCTAssertEqual(AsdGgufContract.audioClipDuration(durationSeconds: 45.0), 30.0)
    }

    func testMediaPromptOrderMatchesServerRequest() {
        XCTAssertEqual(
            AsdGgufContract.promptWithMediaMarkers(mediaCount: 4, userPrompt: "instruction"),
            "<__media__><__media__><__media__><__media__>instruction"
        )
        XCTAssertEqual(AsdGgufContract.promptWithMediaMarkers(mediaCount: 0, userPrompt: "instruction"), "instruction")
    }
}
