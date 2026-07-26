import AVFoundation
import Foundation

/// Renders an asset's audio independently from AVPlayer while enhanced video
/// is presented by the VideoToolbox pipeline.
@MainActor
final class EnhancedAudioPipeline {
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let feedQueue = DispatchQueue(label: "dev.mqiu.VTPlayer.enhanced-audio")

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var isStarted = false
    private var isFinished = false

    init() {
        synchronizer.addRenderer(renderer)
        // Sample buffers may be queued well before enhanced video is ready.
        // Hold the audio timeline until the first frame is actually rendered.
        synchronizer.setRate(0, time: .zero)
    }

    func prepare(url: URL, startTime: CMTime) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return false
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)

        if startTime > .zero {
            let duration = try await asset.load(.duration)
            let remaining = CMTimeSubtract(duration, startTime)
            guard remaining > .zero else { return false }
            reader.timeRange = CMTimeRange(start: startTime, duration: remaining)
        }

        guard reader.startReading() else { return false }
        self.reader = reader
        self.output = output
        requestSamples()
        return true
    }

    func start(at presentationTime: CMTime) {
        guard !isStarted else { return }
        isStarted = true
        synchronizer.setRate(1, time: presentationTime)
    }

    func pause() {
        guard isStarted else { return }
        synchronizer.setRate(0, time: synchronizer.currentTime())
    }

    func resume() {
        guard isStarted else { return }
        synchronizer.setRate(1, time: synchronizer.currentTime())
    }

    func stop() {
        renderer.stopRequestingMediaData()
        synchronizer.setRate(0, time: synchronizer.currentTime())
        renderer.flush()
        reader?.cancelReading()
        reader = nil
        output = nil
        isStarted = false
        isFinished = true
    }

    private func requestSamples() {
        renderer.requestMediaDataWhenReady(on: feedQueue) { [weak self] in
            Task { @MainActor [weak self] in
                self?.enqueueAvailableSamples()
            }
        }
    }

    private func enqueueAvailableSamples() {
        guard !isFinished, let output else { return }

        while renderer.isReadyForMoreMediaData {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                renderer.stopRequestingMediaData()
                isFinished = true
                return
            }
            renderer.enqueue(sampleBuffer)
        }
    }
}
