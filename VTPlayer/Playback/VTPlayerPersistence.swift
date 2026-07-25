import Foundation
import CryptoKit
import SwiftUI
import AVFoundation
import VideoToolbox

extension VTPlayerViewModel {
    // MARK: - Per-Video Settings Persistence

    private static var videoHistoryKeyPrefixes: [String] {
        [
            "VTSettings_",
            "VTVideoSettings_",
            "VTPlaybackProgress_",
            "VTLastSRLevel_",
            "VTLastFILevel_",
            "VTLastQSRLevel_",
            "VTLastMBLevel_",
            "VTLastDNLevel_",
            "VTLastSharpness_",
            "VTLastHDRBoost_",
            "VTLastHDRColorfulness_",
            "VTLastPosition_",
            "VTSecurityScopedBookmarkMac."
        ]
    }

    private static var videoHistoryKeys: [String] {
        [
            "VTRecentVideos",
            "VTRecentVideosMac",
            "VTRecentVideosDates",
            "VTRecentVideosDatesMac",
            "VTRecentVideosOpenedDates",
            "VTRecentVideosOpenedDatesMac",
            "VTImportedVideoIdentifiers",
            "VTRemovedRecentVideos",
            "VTPinnedVideos",
            "VTSecurityScopedBookmarksMac"
        ]
    }

    func clearPersistedVideoHistory() {
        let defaults = UserDefaults.standard
        let keysToRemove = defaults.dictionaryRepresentation().keys.filter { key in
            Self.videoHistoryKeys.contains(key) ||
            Self.videoHistoryKeyPrefixes.contains { key.hasPrefix($0) }
        }

        for key in keysToRemove {
            defaults.removeObject(forKey: key)
        }
    }

    static func videoSettingsKey(for path: String) -> String {
        return "VTSettings_\(path)"
    }

    func saveVideoSettings() {
        guard let url = videoURL else { return }
        let settings: [String: Any] = [
            "superResolutionLevel": superResolutionLevel,
            "frameInterpolationLevel": frameInterpolationLevel,
            "playbackSpeed": playbackSpeed,
            "volume": volume,
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
        volume = settings["volume"] as? Double ?? 1.0
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
        superResolutionLevel = 0
        frameInterpolationLevel = UserDefaults.standard.integer(forKey: "VTDefaultFILevel")
        playbackSpeed = 1.0
        volume = 1.0
        
        let defSharp = UserDefaults.standard.double(forKey: "VTDefaultSharpness")
        sharpness = defSharp
        renderer.sharpness = Float(defSharp)
        
        let defHDR = UserDefaults.standard.double(forKey: "VTDefaultHDRBoost")
        hdrStrength = defHDR
        renderer.hdrStrength = Float(defHDR)

        let defHDRColorfulness = UserDefaults.standard.double(forKey: "VTDefaultHDRColorfulness")
        hdrColorfulness = defHDRColorfulness
        renderer.hdrColorfulness = Float(defHDRColorfulness)
        
        qualitySuperResolutionScaleFactor = 0
        motionBlurStrength = UserDefaults.standard.integer(forKey: "VTDefaultMBLevel")
        denoiseStrength = UserDefaults.standard.double(forKey: "VTDefaultDNLevel")
        qualityPrioritization = 1
    }

    #if os(iOS)
    private func contentFingerprint(for url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var digest = SHA256()
        let sampleSize = 1024 * 1024
        let fileSize: Int64 = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int64.zero
        digest.update(data: Data(String(fileSize).utf8))

        if let firstChunk = try? handle.read(upToCount: sampleSize) {
            digest.update(data: firstChunk)
        }
        if fileSize > Int64(sampleSize) {
            try? handle.seek(toOffset: UInt64(fileSize - Int64(sampleSize)))
            if let lastChunk = try? handle.read(upToCount: sampleSize) {
                digest.update(data: lastChunk)
            }
        }
        return Data(digest.finalize())
    }

    func existingImportedVideo(forIdentifier identifier: String) -> URL? {
        guard let identifiers = UserDefaults.standard.dictionary(forKey: "VTImportedVideoIdentifiers") as? [String: String],
              let path = identifiers[identifier] else { return nil }
        let url = URL(fileURLWithPath: path)
        guard isManagedImportedVideo(url), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func saveImportedVideoIdentifier(_ identifier: String, for url: URL) {
        var identifiers = UserDefaults.standard.dictionary(forKey: "VTImportedVideoIdentifiers") as? [String: String] ?? [:]
        identifiers[identifier] = url.standardizedFileURL.path
        UserDefaults.standard.set(identifiers, forKey: "VTImportedVideoIdentifiers")
    }

    func existingImportedVideo(matching sourceURL: URL) -> URL? {
        let candidates = recentVideos.filter {
            isManagedImportedVideo($0) && FileManager.default.fileExists(atPath: $0.path)
        }
        guard !candidates.isEmpty else { return nil }
        guard let sourceDigest = contentFingerprint(for: sourceURL) else { return nil }
        let sourceSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize

        for candidate in candidates {
            let candidateSize = (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard sourceSize == candidateSize,
                  contentFingerprint(for: candidate) == sourceDigest else { continue }
            return candidate
        }
        return nil
    }

    func importedVideosDirectoryURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = applicationSupportDirectory.appendingPathComponent(
            "VTPlayer/ImportedVideos",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func isManagedImportedVideo(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(importedVideosDirectoryURL().standardizedFileURL.path + "/")
    }

    func deleteTempFile(for url: URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let isTemporaryFile = url.standardizedFileURL.path.hasPrefix(tempDir.standardizedFileURL.path + "/")
        let isManagedFile = isManagedImportedVideo(url)
        if isTemporaryFile || isManagedFile {
            try? FileManager.default.removeItem(at: url)
            if isManagedFile {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
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
            if let markerRange = url.path.range(of: "/VTPlayer/ImportedVideos/") {
                let relativePath = String(url.path[markerRange.upperBound...])
                return importedVideosDirectoryURL().appendingPathComponent(relativePath)
            }
            return url
        }

        let activePaths = Set(loadedURLs.map { $0.standardizedFileURL.path })
        
        // Clean up temp directory files that are NOT in the recents list
        if let tempFiles = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for fileURL in tempFiles {
                if !activePaths.contains(fileURL.standardizedFileURL.path) {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }

        let importedDirectory = importedVideosDirectoryURL()
        if let importedFiles = FileManager.default.enumerator(
            at: importedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for case let fileURL as URL in importedFiles {
                let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory != true else { continue }
                if !activePaths.contains(fileURL.standardizedFileURL.path) {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
        
        // Filter out stale temp URLs whose files no longer exist
        self.recentVideos = loadedURLs.filter { url in
            if url.standardizedFileURL.path.hasPrefix(tempDir.standardizedFileURL.path + "/") ||
                isManagedImportedVideo(url) {
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
    
    func addToRecentVideosIOS(_ url: URL, importIdentifier: String? = nil) {
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
        if let importIdentifier {
            saveImportedVideoIdentifier(importIdentifier, for: standardURL)
        }
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
        withAnimation(.easeInOut(duration: 0.25)) {
            self.recentVideos.remove(atOffsets: indexSet)
        }
        saveRecentVideosIOS()
        removeRecentDateEntries(for: removedURLs)

        if let selectedURL = videoURL,
           removedURLs.contains(where: { $0 == selectedURL }) {
            stop()
            videoURL = nil
        }
    }

    func clearRecentVideosIOS() {
        if videoURL != nil {
            stop()
            videoURL = nil
        }

        for url in recentVideos {
            deleteTempFile(for: url)
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            self.recentVideos.removeAll()
        }
        clearPersistedVideoHistory()

        if let scoped = securityScopedURL {
            scoped.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
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
