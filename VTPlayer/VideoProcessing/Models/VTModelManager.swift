//
//  VTModelManager.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import Foundation
import Observation

#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
import VideoToolbox

/// A manager class responsible for checking, downloading, and reporting the progress of
/// machine learning models required by VideoToolbox frame processors.
@Observable
@MainActor
public final class VTModelManager {
    
    /// The current status of the model.
    public enum Status: Sendable, Equatable {
        case notChecked
        case ready
        case downloadRequired
        case downloading(progress: Double)
        case failed(String)
    }
    
    /// The observable status of the model manager.
    public private(set) var status: Status = .notChecked

    /// Tracks whether the asynchronous download has completed (success or failure).
    private var downloadCompleted = false
    private var progressTask: Task<Void, Never>?

    public init() {}
    
    /// Checks the model status for the given configuration.
    /// - Parameter configuration: The VideoToolbox frame processor configuration to check.
    public func checkStatus(for configuration: VTFrameProcessorConfiguration) {
        guard let srConfig = configuration as? VTSuperResolutionScalerConfiguration else {
            // Other configurations (e.g. low-latency interpolation) do not require model downloads.
            status = .ready
            return
        }
        
        switch srConfig.configurationModelStatus {
        case .ready:
            status = .ready
        case .downloadRequired:
            status = .downloadRequired
        case .downloading:
            let progress = srConfig.configurationModelPercentageAvailable
            status = .downloading(progress: Double(progress))
        @unknown default:
            status = .notChecked
        }
    }
    
    /// Starts downloading the machine learning weights for the given configuration.
    /// - Parameter configuration: The configuration whose model needs to be downloaded.
    public func downloadModel(for configuration: VTFrameProcessorConfiguration) {
        guard let srConfig = configuration as? VTSuperResolutionScalerConfiguration else {
            // Other configurations do not require model downloads.
            self.status = .ready
            return
        }

        // Double check if model is already ready
        if srConfig.configurationModelStatus == .ready {
            self.status = .ready
            return
        }

        self.status = .downloading(progress: Double(srConfig.configurationModelPercentageAvailable))
        self.downloadCompleted = false

        // Start downloading configuration model with a completion handler
        srConfig.downloadConfigurationModel { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.downloadCompleted = true
                if let error = error {
                    self.status = .failed(error.localizedDescription)
                } else {
                    self.status = .ready
                }
            }
        }

        // Poll on the main actor without capturing Timer in a concurrently
        // executing closure. The task ends when the download completion handler
        // updates downloadCompleted or when the model manager starts another
        // download.
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self, srConfig] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self else { return }
                guard !self.downloadCompleted else { return }

                switch srConfig.configurationModelStatus {
                case .downloading:
                    let progress = srConfig.configurationModelPercentageAvailable
                    self.status = .downloading(progress: Double(progress))
                case .ready:
                    self.status = .ready
                    return
                case .downloadRequired:
                    // Keep the downloading state until the completion handler
                    // reports a final result.
                    break
                @unknown default:
                    return
                }
            }
        }
    }
}
#endif
