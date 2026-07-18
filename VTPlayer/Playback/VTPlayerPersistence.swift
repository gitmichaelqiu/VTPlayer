import Foundation
import SwiftUI
import AVFoundation
import VideoToolbox

extension VTPlayerViewModel {
    // MARK: - Per-Video Settings Persistence

    static func videoSettingsKey(for path: String) -> String {
        return "VTSettings_\(path)"
    }

    func saveVideoSettings() {
        guard let url = videoURL else { return }
        let settings: [String: Any] = [
            "superResolutionLevel": superResolutionLevel,
            "frameInterpolationLevel": frameInterpolationLevel,
            "playbackSpeed": playbackSpeed,
            "sharpness": sharpness,
            "hdrStrength": hdrStrength,
            "hdrColorfulness": hdrColorfulness,
            "qualitySuperResolutionScaleFactor": qualitySuperResolutionScaleFactor,
            "motionBlurStrength": motionBlurStrength,
            "denoiseStrength": denoiseStrength,
            "qualityPrioritization": qualityPrioritization,
        ]
        UserDefaults.standard.set(settings, forKey: Self.videoSettingsKey(for: url.lastPathComponent))
    }

    func loadVideoSettings(for url: URL) {
        guard let settings = UserDefaults.standard.dictionary(forKey: Self.videoSettingsKey(for: url.lastPathComponent)) else {
            applyDefaultPlaybackSettings()
            return
        }
        superResolutionLevel = settings["superResolutionLevel"] as? Int ?? 0
        frameInterpolationLevel = settings["frameInterpolationLevel"] as? Int ?? 0
        playbackSpeed = settings["playbackSpeed"] as? Double ?? 1.0
        let loadedSharpness = settings["sharpness"] as? Double ?? 0.0
        if loadedSharpness != sharpness {
            sharpness = loadedSharpness
        }
        renderer.sharpness = Float(sharpness)
        hdrStrength = settings["hdrStrength"] as? Double ?? 0.0
        renderer.hdrStrength = Float(hdrStrength)
        hdrColorfulness = settings["hdrColorfulness"] as? Double ?? 0.0
        renderer.hdrColorfulness = Float(hdrColorfulness)
        qualitySuperResolutionScaleFactor = settings["qualitySuperResolutionScaleFactor"] as? Int ?? 0
        motionBlurStrength = settings["motionBlurStrength"] as? Int ?? 0
        denoiseStrength = settings["denoiseStrength"] as? Double ?? 0.0
        qualityPrioritization = settings["qualityPrioritization"] as? Int ?? 1
    }

    func applyDefaultPlaybackSettings() {
        superResolutionLevel = UserDefaults.standard.integer(forKey: "VTDefaultSRLevel")
        frameInterpolationLevel = UserDefaults.standard.integer(forKey: "VTDefaultFILevel")
        playbackSpeed = 1.0
        
        let defSharp = UserDefaults.standard.double(forKey: "VTDefaultSharpness")
        sharpness = defSharp
        renderer.sharpness = Float(defSharp)
        
        let defHDR = UserDefaults.standard.double(forKey: "VTDefaultHDRBoost")
        hdrStrength = defHDR
        renderer.hdrStrength = Float(defHDR)

        let defHDRColorfulness = UserDefaults.standard.double(forKey: "VTDefaultHDRColorfulness")
        hdrColorfulness = defHDRColorfulness
        renderer.hdrColorfulness = Float(defHDRColorfulness)
        
        // Load the requested Quality SR default before capability validation;
        // model readiness and per-scale support are checked when the video is
        // opened, rather than silently converting or discarding QL2 here.
        qualitySuperResolutionScaleFactor = UserDefaults.standard.integer(forKey: "VTDefaultQSRLevel")
        motionBlurStrength = UserDefaults.standard.integer(forKey: "VTDefaultMBLevel")
        denoiseStrength = UserDefaults.standard.double(forKey: "VTDefaultDNLevel")
        qualityPrioritization = 1
    }

    #if os(iOS)
    func deleteTempFile(for url: URL) {
        let tempDir = FileManager.default.temporaryDirectory
        if url.standardizedFileURL.path.hasPrefix(tempDir.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func loadRecentVideosIOS() {
        let paths = UserDefaults.standard.stringArray(forKey: "VTRecentVideos") ?? []
        let tempDir = FileManager.default.temporaryDirectory
        
        let loadedURLs = paths.compactMap { pathString -> URL? in
            guard let url = URL(string: pathString) else { return nil }
            // Reconstruct temp URLs to handle container UUID changes on iOS
            if pathString.contains("/tmp/") {
                let filename = url.lastPathComponent
                return tempDir.appendingPathComponent(filename)
            }
            return url
        }
        
        // Clean up temp directory files that are NOT in the recents list
        if let tempFiles = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            let activePaths = Set(loadedURLs.map { $0.standardizedFileURL.path })
            for fileURL in tempFiles {
                if !activePaths.contains(fileURL.standardizedFileURL.path) {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
        
        // Filter out stale temp URLs whose files no longer exist
        self.recentVideos = loadedURLs.filter { url in
            if url.standardizedFileURL.path.hasPrefix(tempDir.standardizedFileURL.path) {
                return FileManager.default.fileExists(atPath: url.path)
            }
            return true // Keep external URLs if any
        }
        saveRecentVideosIOS() // persist cleaned list
    }
    
    func saveRecentVideosIOS() {
        let paths = self.recentVideos.map { $0.absoluteString }
        UserDefaults.standard.set(paths, forKey: "VTRecentVideos")
    }
    
    func checkGlobalModelStatus() {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
           VTSuperResolutionScalerConfiguration.isSupported {
            if let config = VTSuperResolutionScalerConfiguration(
                frameWidth: 1920, frameHeight: 1080,
                scaleFactor: 4, inputType: .video,
                usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: .revision1
            ) {
                modelManager.checkStatus(for: config)
            }
        }
    }
    
    func downloadGlobalModel() {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
           VTSuperResolutionScalerConfiguration.isSupported {
            if let config = VTSuperResolutionScalerConfiguration(
                frameWidth: 1920, frameHeight: 1080,
                scaleFactor: 4, inputType: .video,
                usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: .revision1
            ) {
                modelManager.downloadModel(for: config)
            }
        }
    }
    
    func addToRecentVideosIOS(_ url: URL) {
        let standardURL = url.resolvingSymlinksInPath().standardizedFileURL
        var list = self.recentVideos.filter { item in
            item.resolvingSymlinksInPath().standardizedFileURL.absoluteString != standardURL.absoluteString
        }
        list.insert(standardURL, at: 0)
        
        // Save the date added timestamp
        let datesKey = "VTRecentVideosDates"
        var dates = UserDefaults.standard.dictionary(forKey: datesKey) as? [String: Double] ?? [:]
        if dates[standardURL.lastPathComponent] == nil {
            dates[standardURL.lastPathComponent] = Date().timeIntervalSince1970
        }
        UserDefaults.standard.set(dates, forKey: datesKey)
        var openedDates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosOpenedDates") as? [String: Double] ?? [:]
        openedDates[standardURL.lastPathComponent] = Date().timeIntervalSince1970
        UserDefaults.standard.set(openedDates, forKey: "VTRecentVideosOpenedDates")
        
        if list.count > 15 {
            // Delete temp files of items falling off the list
            for staleURL in list.suffix(from: 15) {
                deleteTempFile(for: staleURL)
            }
            list = Array(list.prefix(15))
        }
        self.recentVideos = list
        saveRecentVideosIOS()
    }
    
    func deleteRecentVideoIOS(at indexSet: IndexSet) {
        let removedURLs = indexSet.compactMap { index in
            recentVideos.indices.contains(index) ? recentVideos[index] : nil
        }

        for idx in indexSet {
            if idx < recentVideos.count {
                deleteTempFile(for: recentVideos[idx])
            }
        }
        self.recentVideos.remove(atOffsets: indexSet)
        saveRecentVideosIOS()
        removeRecentDateEntries(for: removedURLs)

        if let selectedURL = videoURL,
           removedURLs.contains(where: { $0 == selectedURL }) {
            stop()
            videoURL = nil
        }
    }

    func clearRecentVideosIOS() {
        for url in recentVideos {
            deleteTempFile(for: url)
        }
        self.recentVideos.removeAll()
        saveRecentVideosIOS()
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosDates")
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosOpenedDates")

        if videoURL != nil {
            stop()
            videoURL = nil
        }
    }

    private func removeRecentDateEntries(for urls: [URL]) {
        let names = Set(urls.map { $0.lastPathComponent })
        for key in ["VTRecentVideosDates", "VTRecentVideosOpenedDates"] {
            var dates = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
            names.forEach { dates.removeValue(forKey: $0) }
            UserDefaults.standard.set(dates, forKey: key)
        }
    }
    #endif

    func fourCharCodeString(_ code: FourCharCode) -> String {
        let n = Int(code)
        let c1 = Character(UnicodeScalar((n >> 24) & 0xff)!)
        let c2 = Character(UnicodeScalar((n >> 16) & 0xff)!)
        let c3 = Character(UnicodeScalar((n >> 8) & 0xff)!)
        let c4 = Character(UnicodeScalar(n & 0xff)!)
        return String([c1, c2, c3, c4]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
