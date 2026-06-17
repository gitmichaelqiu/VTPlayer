//
//  VTModelManager.swift
//  VTPlayer
//
//  Created by Michael Qiu on 6/17/26.
//

import Foundation
import VideoToolbox
import Observation

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
        
        // Start downloading configuration model with a completion handler
        srConfig.downloadConfigurationModel { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.status = .failed(error.localizedDescription)
                } else {
                    self.status = .ready
                }
            }
        }
        
        // Start a timer to poll progress while downloading
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, srConfig] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                
                switch srConfig.configurationModelStatus {
                case .downloading:
                    let progress = srConfig.configurationModelPercentageAvailable
                    self.status = .downloading(progress: Double(progress))
                case .ready:
                    self.status = .ready
                    timer.invalidate()
                case .downloadRequired:
                    self.status = .downloadRequired
                    timer.invalidate()
                @unknown default:
                    timer.invalidate()
                }
            }
        }
    }
}
