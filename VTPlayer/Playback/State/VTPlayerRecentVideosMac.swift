#if os(macOS)
import SwiftUI
import AppKit

extension VTPlayerViewModel {
    private func securityBookmarkKey(for url: URL) -> String {
        "VTSecurityScopedBookmarkMac.\(url.standardizedFileURL.path)"
    }

    func saveSecurityScopedBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: securityBookmarkKey(for: url))
            // Ensure the grant is on disk before the app is rebuilt or
            // terminated immediately after opening a file.
            UserDefaults.standard.synchronize()
            NSLog("SECURITY: saved bookmark for %@", url.path)
        } catch {
            print("Failed to save security-scoped bookmark: \(error.localizedDescription)")
        }
    }

    func resolveSecurityScopedBookmark(for url: URL) -> URL {
        let path = url.standardizedFileURL.path
        let legacyBookmarks = UserDefaults.standard.dictionary(forKey: "VTSecurityScopedBookmarksMac")
        let legacyBookmark = legacyBookmarks?[path] as? Data
        guard let bookmark = UserDefaults.standard.data(forKey: securityBookmarkKey(for: url)) ?? legacyBookmark else { return url }
        var isStale = false
        do {
            let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale { saveSecurityScopedBookmark(for: resolved) }
            NSLog("SECURITY: resolved bookmark for %@ (stale=%@)", path, isStale ? "YES" : "NO")
            return resolved
        } catch {
            print("Failed to resolve security-scoped bookmark: \(error.localizedDescription)")
            return url
        }
    }

    func removeSecurityScopedBookmark(for url: URL) {
        UserDefaults.standard.removeObject(forKey: securityBookmarkKey(for: url))
    }

    @objc func reloadRecentVideos() {
        for scopedURL in recentSecurityScopedURLs {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        recentSecurityScopedURLs.removeAll(keepingCapacity: true)
        let paths = UserDefaults.standard.stringArray(forKey: "VTRecentVideosMac")
        if let paths = paths {
            var urls: [URL] = []
            for path in paths {
                if let url = URL(string: path) {
                    let resolved = resolveSecurityScopedBookmark(for: url)
                    if resolved.startAccessingSecurityScopedResource() {
                        recentSecurityScopedURLs.append(resolved)
                    }
                    urls.append(resolved)
                }
            }
            self.recentVideos = urls
        } else {
            // First-run migration from NSDocumentController if available
            let removed = UserDefaults.standard.stringArray(forKey: "VTRemovedRecentVideos") ?? []
            let urls = NSDocumentController.shared.recentDocumentURLs.filter { url in
                !removed.contains(url.path)
            }
            self.recentVideos = urls
            let paths = urls.map { $0.absoluteString }
            UserDefaults.standard.set(paths, forKey: "VTRecentVideosMac")
        }
    }

    func recordRecentDateIfNeeded(for url: URL) {
        var addedDates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDatesMac") as? [String: Double] ?? [:]
        if addedDates[url.path] == nil {
            addedDates[url.path] = Date().timeIntervalSince1970
            UserDefaults.standard.set(addedDates, forKey: "VTRecentVideosDatesMac")
        }
        var openedDates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosOpenedDatesMac") as? [String: Double] ?? [:]
        openedDates[url.path] = Date().timeIntervalSince1970
        UserDefaults.standard.set(openedDates, forKey: "VTRecentVideosOpenedDatesMac")
    }

    func addRecentVideoMac(_ url: URL) {
        var list = self.recentVideos.filter { $0 != url }
        list.insert(url, at: 0)
        if list.count > 50 {
            list = Array(list.prefix(50))
        }
        self.recentVideos = list
        
        let paths = list.map { $0.absoluteString }
        UserDefaults.standard.set(paths, forKey: "VTRecentVideosMac")

        #if os(macOS)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        #endif
    }
    
    func deleteRecentVideoMac(at url: URL) {
        let wasSelected = videoURL == url
        clearPersistedVideoState(for: url)
        self.recentVideos.removeAll { $0 == url }
        
        let paths = self.recentVideos.map { $0.absoluteString }
        UserDefaults.standard.set(paths, forKey: "VTRecentVideosMac")

        var dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDatesMac") as? [String: Double] ?? [:]
        dates.removeValue(forKey: url.path)
        UserDefaults.standard.set(dates, forKey: "VTRecentVideosDatesMac")
        removeSecurityScopedBookmark(for: url)
        
        var openedDates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosOpenedDatesMac") as? [String: Double] ?? [:]
        openedDates.removeValue(forKey: url.path)
        UserDefaults.standard.set(openedDates, forKey: "VTRecentVideosOpenedDatesMac")

        if wasSelected {
            stop()
            videoURL = nil
        }
    }

    func clearRecentVideosMac() {
        let hadSelectedVideo = videoURL != nil
        #if os(macOS)
        NSDocumentController.shared.clearRecentDocuments(nil)
        #endif
        withAnimation(.easeInOut(duration: 0.25)) {
            self.recentVideos.removeAll()
        }
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosMac")
        UserDefaults.standard.removeObject(forKey: "VTRemovedRecentVideos")
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosDatesMac")
        UserDefaults.standard.removeObject(forKey: "VTRecentVideosOpenedDatesMac")

        if hadSelectedVideo {
            stop()
            videoURL = nil
        }

        clearPersistedVideoHistory()
    }
}
#endif
