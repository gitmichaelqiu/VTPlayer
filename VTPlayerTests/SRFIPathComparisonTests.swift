#if os(macOS) && DEBUG
import CoreImage
import CoreMedia
import XCTest
@testable import VTPlayer

final class SRFIPathComparisonTests: XCTestCase {
    private struct Configuration: Decodable {
        let video: String
        let width: Int
        let height: Int
        let startSeconds: Double
        let frameCount: Int
        let outputDirectory: String
    }

    func testTemporalFirst() async throws {
        try await compare(spatialFirst: false)
    }

    func testSpatialFirst() async throws {
        try await compare(spatialFirst: true)
    }

    private func compare(spatialFirst: Bool) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let configURL = root.appendingPathComponent("tmp/srfi-comparison.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("Create tmp/srfi-comparison.json to run the SR/FI comparison.")
        }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
        XCTAssertGreaterThan(config.frameCount, 1)
        guard config.frameCount > 1 else { return }

        let processor = VTFrameProcessorCoordinator(
            superResolutionLevel: 2,
            frameInterpolationLevel: 2,
            preferSequentialSRFI: true
        )
        if spatialFirst { await processor.selectSpatialFirstForDiagnostics() }
        var sourceIndex = -1
        do {
            try await processor.startSession(width: config.width, height: config.height)
            let padding = await processor.sourceFramePadding()
            let iterator = VTFrameSequence(
                url: URL(fileURLWithPath: config.video),
                startTime: CMTime(seconds: config.startSeconds, preferredTimescale: 600),
                extendedPixelsRight: padding.right,
                extendedPixelsBottom: padding.bottom
            ).makeAsyncIterator()
            var durations: [Double] = []
            var interpolatedFrame: VTFrame?
            for index in 0..<config.frameCount {
                sourceIndex = index
                guard let frame = try await iterator.next() else {
                    XCTFail("The fixture ended after \(index) source frames.")
                    break
                }
                let start = DispatchTime.now().uptimeNanoseconds
                let frames = try await processor.processFrame(frame)
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                if index > 0 {
                    XCTAssertEqual(frames.count, 2)
                    durations.append(seconds)
                    if index == config.frameCount / 2 {
                        interpolatedFrame = frames.first(where: \.isInterpolated)
                    }
                }
            }
            XCTAssertEqual(durations.count, config.frameCount - 1)
            if !durations.isEmpty {
                let sorted = durations.sorted()
                let mean = durations.reduce(0, +) / Double(durations.count)
                let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
                print("SRFI_COMPARISON order=\(spatialFirst ? "spatial-first" : "temporal-first") samples=\(durations.count) meanMs=\(mean * 1000) p95Ms=\(p95 * 1000)")
            }
            let output = try XCTUnwrap(interpolatedFrame)
            XCTAssertEqual(CVPixelBufferGetWidth(output.buffer), config.width * 2)
            XCTAssertEqual(CVPixelBufferGetHeight(output.buffer), config.height * 2)
            let directory = URL(fileURLWithPath: config.outputDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = CIImage(cvPixelBuffer: output.buffer)
            let outputURL = directory.appendingPathComponent(spatialFirst ? "spatial-first.png" : "temporal-first.png")
            try CIContext().writePNGRepresentation(of: image, to: outputURL, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            await processor.endSession()
        } catch {
            print("SRFI_COMPARISON order=\(spatialFirst ? "spatial-first" : "temporal-first") sourceIndex=\(sourceIndex) error=\(error)")
            await processor.endSession()
            throw error
        }
    }
}
#endif
