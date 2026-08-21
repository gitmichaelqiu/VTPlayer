import SwiftUI
import AVKit
import AVFoundation


extension VTPlayerView {
    #if os(iOS)
    @ViewBuilder
    var iosHomeView: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ZStack {
                    iosGalleryView
                }
                .navigationTitle("Gallery")
                .navigationBarTitleDisplayMode(.large)
                    .navigationDestination(isPresented: $isPlayerPresented) {
                        iosPlayerView
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            if !viewModel.recentVideos.isEmpty {
                                Button(action: { showClearAllAlert = true }) {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }

                                Menu {
                                    Picker("Sort By", selection: Binding(
                                        get: { sortBy },
                                        set: { newValue in
                                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                                sortBy = newValue
                                            }
                                        }
                                    )) {
                                        Label("Date Added", systemImage: "calendar").tag(SortOption.dateAdded)
                                        Label("Date Opened", systemImage: "clock.arrow.circlepath").tag(SortOption.dateOpened)
                                        Label("Name", systemImage: "textformat.abc").tag(SortOption.name)
                                    }
                                } label: {
                                    Image(systemName: "arrow.up.arrow.down")
                                }
                            }

                            Menu {
                                Button(action: { showFileImporter = true }) {
                                    Label("Browse Files", systemImage: "folder")
                                }

                                #if canImport(PhotosUI)
                                Button {
                                    showPhotoPicker = true
                                } label: {
                                    Label("Photos Library", systemImage: "photo")
                                }
                                #endif
                            } label: {
                                Image(systemName: "plus")
                                    .font(.body.bold())
                            }
                        }
                    }
            }
                .tag(0)
                .tabItem {
                    Label("Gallery", systemImage: "play.square.stack.fill")
                }

            NavigationStack {
                iosAboutView
                    .navigationTitle("About")
            }
                .tag(1)
                .tabItem {
                    Label("About", systemImage: "info.circle.fill")
                }
        }
        .toolbar(isPlayerTabBarHidden ? .hidden : .visible, for: .tabBar)
        .onChange(of: viewModel.videoURL) { _, url in
            if url != nil {
                isPlayerNavigationReady = false
                isPlayerPresented = true
            } else {
                isPlayerNavigationReady = false
                isPlayerPresented = false
            }
        }
        .onChange(of: isPlayerPresented) { _, presented in
            guard !presented, viewModel.videoURL != nil else { return }

            // Dismiss through the navigation destination's state first. The
            // URL is playback state, not the presentation mechanism.
            withAnimation(.easeInOut(duration: 0.25)) {
                isPlayerTabBarHidden = false
            }
            viewModel.stop()
            viewModel.videoURL = nil
        }
    }

    @ViewBuilder
    var iosGalleryView: some View {
        Group {
            if viewModel.recentVideos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("No Videos")
                        .font(.headline)
                    Text("Tap the + button to add video files.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            } else {
                let sortedVideos: [URL] = {
                    let pinnedList = viewModel.recentVideos.filter { pinnedVideos.contains($0.lastPathComponent) }
                    let unpinnedList = viewModel.recentVideos.filter { !pinnedVideos.contains($0.lastPathComponent) }

                    let sortBlock: (URL, URL) -> Bool = { u1, u2 in
                        switch sortBy {
                        case .name:
                            return u1.lastPathComponent.localizedStandardCompare(u2.lastPathComponent) == .orderedAscending
                        case .dateAdded:
                            let dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosDates") as? [String: Double] ?? [:]
                            let t1 = dates[u1.lastPathComponent] ?? 0
                            let t2 = dates[u2.lastPathComponent] ?? 0
                            return t1 > t2
                        case .dateOpened:
                            let dates = UserDefaults.standard.dictionary(forKey: "VTRecentVideosOpenedDates") as? [String: Double] ?? [:]
                            return (dates[u1.lastPathComponent] ?? 0) > (dates[u2.lastPathComponent] ?? 0)
                        }
                    }

                    return pinnedList.sorted(by: sortBlock) + unpinnedList.sorted(by: sortBlock)
                }()

                let pinnedList = sortedVideos.filter { pinnedVideos.contains($0.lastPathComponent) }
                let unpinnedList = sortedVideos.filter { !pinnedVideos.contains($0.lastPathComponent) }

                List {
                    if !pinnedList.isEmpty {
                        Section(isExpanded: $isPinnedExpanded) {
                            ForEach(pinnedList, id: \.self) { url in
                                videoRow(for: url)
                                    .id("\(url.path)-pinned")
                            }
                        } header: {
                            Text("Pinned")
                        }
                    }

                    Section(isExpanded: $isRecentsExpanded) {
                        ForEach(unpinnedList, id: \.self) { url in
                            videoRow(for: url)
                                .id("\(url.path)-unpinned")
                        }
                    } header: {
                        if !pinnedList.isEmpty {
                            Text("Videos")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .alert("Clear All Videos?", isPresented: $showClearAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                pinnedVideos.removeAll()
                viewModel.clearRecentVideosIOS()
            }
        } message: {
            Text("This will clear your recent playback history. The original video files will not be deleted.")
        }

    }

    @ViewBuilder
    func videoRow(for url: URL) -> some View {
        Button(action: {
            viewModel.openVideo(url)
        }) {
            HStack(spacing: 12) {
                VideoThumbnailView(url: url)

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.displayName(for: url, showingExtension: showFileExtensions))
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text(sortBy == .dateOpened ? formatDateOpened(for: url) : formatDateAdded(for: url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                togglePin(for: url)
            } label: {
                Label(pinnedVideos.contains(url.lastPathComponent) ? "Unpin" : "Pin",
                      systemImage: pinnedVideos.contains(url.lastPathComponent) ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                if let idx = viewModel.recentVideos.firstIndex(of: url) {
                    viewModel.deleteRecentVideoIOS(at: IndexSet(integer: idx))
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                togglePin(for: url)
            } label: {
                let isPinned = pinnedVideos.contains(url.lastPathComponent)
                Label(isPinned ? "Unpin Video" : "Pin Video", systemImage: isPinned ? "pin.slash" : "pin")
            }

            Button {
                videoToRename = url
                renameText = viewModel.displayName(for: url, showingExtension: false)
                showRenameAlert = true
            } label: {
                Label("Rename File", systemImage: "pencil")
            }

            Button {
                UIPasteboard.general.string = url.lastPathComponent
            } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }

            ShareLink(item: url, preview: SharePreview(url.lastPathComponent))

            Divider()

            Button(role: .destructive) {
                if let idx = viewModel.recentVideos.firstIndex(of: url) {
                    viewModel.deleteRecentVideoIOS(at: IndexSet(integer: idx))
                }
            } label: {
                Label("Remove from List", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    func modelStatusLabelView(_ status: VTModelManager.Status) -> some View {
        switch status {
        case .notChecked:
            Text("Checking...")
                .foregroundStyle(.secondary)
        case .ready:
            Text("Ready")
                .foregroundStyle(.green)
                .bold()
        case .downloadRequired:
            Text("Download Required")
                .foregroundStyle(.orange)
        case .downloading(let progress):
            let percent = progress.formatted(.percent.precision(.fractionLength(0)))
            Text(String(localized: "Downloading %@", defaultValue: "Downloading \(percent)", comment: "Model download progress"))
                .foregroundStyle(.blue)
        case .failed:
            Text("Failed")
                .foregroundStyle(.red)
        }
    }

    #endif
}
