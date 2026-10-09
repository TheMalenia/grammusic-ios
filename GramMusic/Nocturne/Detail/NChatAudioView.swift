import SwiftUI

/// One chat's audio in Nocturne style (screens §6). Hero avatar + name + meta, Play / Shuffle,
/// a sort + Download-all control row, find-in-chat, then a paginated artwork track list.
struct NChatAudioView: View {
    let chat: TelegramChat
    var showBackButton: Bool = true

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerEngine.self) private var player
    @Environment(NActionFeedback.self) private var feedback: NActionFeedback?
    @Environment(TelegramService.self) private var telegram
    @Environment(ImportStore.self) private var importStore

    @State private var selection = NTrackSelection()
    @State private var tracks: [AudioTrack] = []
    @State private var isLoading = true
    @State private var loadingMore = false
    @State private var nextFromId: Int64?
    @State private var error: String?
    @State private var actionTarget: AudioTrack?
    @State private var newestFirst = true
    @State private var showSearch = false
    @State private var isRefreshing = false
    @State private var showReportChat = false
    @State private var showBlockConfirm = false

    @State private var shuffleGeneration = 0
    @State private var preparingShuffle = false
    @State private var shuffleError: String?
    @State private var showShuffleError = false

    private let pageSize = 100

    /// Loaded tracks in the chosen order (newest-first is the load order).
    private var sortedTracks: [AudioTrack] { newestFirst ? tracks : tracks.reversed() }

    private var selectionIncludesHidden: Bool {
        let candidates = selection.includesUnloaded
            ? sortedTracks + telegram.hiddenTracks.tracks.filter { $0.chatId == chat.id }
            : sortedTracks
        return selection.containsHidden(in: candidates, hiddenIDs: telegram.hiddenTracks.ids)
    }

    private var selectionCollectionLoader: TrackCollectionLoader {
        let order = newestFirst
        return {
            let loaded = try await telegram.allChatAudio(in: chat.id)
            return order ? loaded : loaded.reversed()
        }
    }

    private var fullCollectionLoader: TrackCollectionLoader {
        let order = newestFirst
        return {
            let loaded = try await telegram.allChatAudio(in: chat.id)
            let visible = telegram.visible(loaded)
            return order ? visible : visible.reversed()
        }
    }

    private var meta: String {
        let n = chat.audioCount ?? tracks.count
        return "\(chat.kindLabel) · \(n) audio file\(n == 1 ? "" : "s")"
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackground()

            LinearGradient(
                colors: [ArtworkSeed(chat.title).accent.opacity(0.55),
                         ArtworkSeed(chat.title).accent.opacity(0.18),
                         theme.bg.opacity(0)],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 360).frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top).allowsHitTesting(false)

            if showBackButton {
                mainList
                    .refreshable { await refresh() }
            } else {
                mainList
            }

            if showBackButton {
                topBar
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipe()      // restore edge-swipe-back (hidden bar disables it)
        .sheet(item: $actionTarget) { track in NTrackActionsSheet(track: track) }
        .sheet(isPresented: $showReportChat) { NReportSheet(chatId: chat.id, messageIds: nil, onDismiss: { showReportChat = false }) }
        .alert(telegram.isLeaveTarget(chat) ? "Leave \(chat.title)?" : "Block \(chat.title)?",
               isPresented: $showBlockConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(telegram.isLeaveTarget(chat) ? "Leave" : "Block", role: .destructive) {
                Task {
                    telegram.isLeaveTarget(chat) ? await telegram.leave(chat: chat)
                                                 : await telegram.block(chat: chat)
                    dismiss()
                }
            }
        } message: {
            Text(telegram.isLeaveTarget(chat)
                 ? "You'll leave this \(chat.kindLabel.lowercased()) on Telegram, and its music will be removed from your library and queue right away."
                 : "Its music will be removed from your library, search and play queue right away, and you won't see it again.")
        }
        .navigationDestination(isPresented: $showSearch) {
            NSearchView(localScope: .init(title: chat.title, tracks: sortedTracks, context: chat.title, loadAll: fullCollectionLoader), isTab: true, embeddedInNavigation: true, onClose: { showSearch = false })
        }
        .task(id: chat.id) { await load() }
        .onAppear { AnalyticsService.logOpenChat() }
        .trackSelection(tracks: sortedTracks, selection: selection, loadAll: selectionCollectionLoader,
                        destructiveTitle: selectionIncludesHidden ? String(localized: "Unhide songs") : String(localized: "Hide songs"),
                        destructiveIcon: selectionIncludesHidden ? "eye" : "eye.slash",
                        requiresDestructiveConfirmation: false,
                        onDestructive: { songs in
                            if songs.contains(where: telegram.isHidden) { telegram.unhideTracks(songs) }
                            else { telegram.hideTracks(songs) }
                        })
        .onDisappear { preparingShuffle = false }
        .task(id: preparingShuffle) {
            if preparingShuffle { await shuffleFullChat() }
        }
        .alert("Couldn't shuffle this chat", isPresented: $showShuffleError) {
            Button("OK", role: .cancel) {}
        } message: { Text(shuffleError ?? "Please try again.") }
    }

    private var mainList: some View {
        List {
            Section {
                hero
                    .listRowInsets(EdgeInsets(top: showBackButton ? 70 : 30, leading: 16, bottom: 12, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                trackList

            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)   // kill the empty gap between the hero and the first track
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .modifier(NScrollDockViewport(base: 24))
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 38, height: 38)
                    .nocturneGlass(Circle(), theme: theme)
                    .frame(width: 44, height: 44)        // ≥44pt tap target around the 38pt glass
                    .contentShape(Circle())
            }
            .buttonStyle(NPressable(scale: 0.9))
            .accessibilityLabel("Back")

            Spacer()

            Menu {
                // Report and Block answer different questions, so they get separate gates.
                // Nesting Block inside `isReportable` hid it for private chats and bots — exactly
                // the sources guideline 1.2 is about.
                if telegram.isReportable(chat: chat) {
                    Button(role: .destructive) {
                        showReportChat = true
                    } label: {
                        Label("Report", systemImage: "exclamationmark.bubble")
                    }
                }
                switch telegram.moderationAction(for: chat) {
                case .leave:
                    Button(role: .destructive) { showBlockConfirm = true } label: {
                        Label("Leave \(chat.kindLabel)", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                case .block:
                    Button(role: .destructive) { showBlockConfirm = true } label: {
                        Label("Block User", systemImage: "hand.raised.fill")
                    }
                case .none:
                    EmptyView()   // Saved Messages: nobody to block, nothing to leave.
                }
                // Hiding is the non-destructive alternative, and the only one that applies to
                // Saved Messages — it just clears the Library row.
                Button {
                    // Hide is organisational, not moderation: it clears the Library row and
                    // nothing else. Deliberately does **not** purge caches or stop playback the
                    // way Leave and Block do — hiding a chat while its song plays should not
                    // silence it.
                    importStore.hideChat(chat.id)
                    dismiss()
                } label: {
                    Label("Hide from Library", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 38, height: 38)
                    .nocturneGlass(Circle(), theme: theme)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            NChatAvatar(chat: chat, size: 148)
                .shadow(color: theme.shadow.opacity(0.5), radius: 18, y: 10)

            VStack(spacing: 4) {
                Text(chat.title).font(.display(26, .bold)).tracking(-0.4)
                    .foregroundStyle(theme.text).multilineTextAlignment(.center).lineLimit(2)
                Text(meta).font(.system(size: 14)).foregroundStyle(theme.text2)
            }

            if !tracks.isEmpty {
                HStack(spacing: 12) {
                    Pill(title: "Play", systemImage: "play.fill", variant: .primary, fullWidth: true) {
                        player.isShuffle = false
                        player.play(tracks: sortedTracks, context: chat.title)
                    }
                    Pill(title: "Shuffle", systemImage: "shuffle", variant: .light, fullWidth: true) {
                        guard !preparingShuffle, !player.isLoading else { return }
                        shuffleGeneration += 1
                        preparingShuffle = true
                    }
                    .disabled(preparingShuffle || player.isLoading)
                    .accessibilityValue(preparingShuffle ? "Preparing shuffle" : "")
                }
                .disabled(preparingShuffle)
                if chat.kind == .bot {
                    Button {
                        if let username = chat.username,
                           let url = URL(string: "tg://resolve?domain=\(username)") {
                            UIApplication.shared.open(url)
                        } else if let url = URL(string: "tg://openmessage?user_id=\(chat.id)") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "message.fill")
                            Text("Open Chat")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(theme.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(NPressable(scale: 0.95))
                }
                controlRow
                SearchBarButton(prompt: "Find in chat") { showSearch = true }
            }
        }
    }

    /// Sort toggle (left) + Download all (right).
    private var controlRow: some View {
        // Explicit-only: the playing track and its lookahead download too, and this button
        // must never offer to stop those.
        let downloading = tracks.filter { telegram.isExplicitlyDownloading($0) }.count
        return HStack {
            Button {
                withAnimation(.snappy(duration: 0.2)) { newestFirst.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                    Text(newestFirst ? "Newest" : "Oldest").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(theme.text2)
            }
            .buttonStyle(NPressable(scale: 0.95))
            .accessibilityLabel("Sort order, \(newestFirst ? "newest first" : "oldest first")")

            Spacer()

            Button {
                if downloading > 0 { telegram.stopDownloads(tracks) }
                else { telegram.downloadAll(tracks) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: downloading > 0 ? "stop.circle" : "arrow.down.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Text(downloading > 0 ? "Stop (\(downloading))" : "Download all")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1).fixedSize()
                }
                .foregroundStyle(theme.accentColor)
            }
            .buttonStyle(NPressable(scale: 0.95))
            .accessibilityLabel(downloading > 0 ? "Stop downloading" : "Download all")
        }
        .sensoryFeedback(.selection, trigger: newestFirst)
    }

    // MARK: Track list

    @ViewBuilder private var trackList: some View {
        if isLoading {
            ForEach(0..<8, id: \.self) { _ in
                skeletonRow
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        } else if let error {
            Text(error)
                .font(.system(size: 15)).foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.top, 40).padding(.horizontal, 24)
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
        } else if sortedTracks.isEmpty {
            Text("No audio in this chat.")
                .font(.system(size: 15)).foregroundStyle(theme.text2)
                .frame(maxWidth: .infinity).padding(.top, 40)
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
        } else {
            if !newestFirst {
                loadingMoreIndicator.id("loader-top-\(tracks.count)")
            }

            ForEach(sortedTracks) { track in
                TrackRow(title: track.displayTitle,
                         subtitle: track.displaySubtitle,
                         seed: track.remoteUniqueId,
                         track: track,
                         isActive: player.current?.remoteUniqueId == track.remoteUniqueId,
                         isPlaying: player.isPlaying,
                         downloaded: telegram.isDownloaded(track),
                         duration: telegram.isHidden(track) ? "Hidden" : track.formattedDuration,
                         onTap: { playFrom(track) },
                         onMore: { actionTarget = track })
                    .opacity(telegram.isHidden(track) ? 0.5 : 1)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        if !selection.isSelecting {
                            Button(telegram.isHidden(track) ? "Unhide song" : "Hide song",
                                   systemImage: telegram.isHidden(track) ? "eye" : "eye.slash") {
                                if telegram.isHidden(track) { telegram.unhideTrack(track) }
                                else { telegram.hideTracks([track]) }
                            }
                            .tint(theme.accentColor)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if !selection.isSelecting && !telegram.isHidden(track) {
                            Button { player.addToQueue(track, feedback: feedback) } label: {
                                Label("Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                            }
                            .tint(theme.accentColor)
                        }
                    }

            }

            if newestFirst {
                loadingMoreIndicator
            }
        }
    }

    @ViewBuilder private var loadingMoreIndicator: some View {
        if let remaining {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading… (\(remaining) remaining)")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.text2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .task {
                await loadMore()
            }
        }
    }

    /// Approx remaining count when more pages exist (full page implies more).
    private var remaining: Int? {
        guard nextFromId != nil else { return nil }
        if let total = chat.audioCount { return max(total - tracks.count, 0) }
        return pageSize     // unknown total: show a page-sized hint
    }

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.elev2).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(theme.elev2).frame(width: 160, height: 12)
                RoundedRectangle(cornerRadius: 4).fill(theme.elev2).frame(width: 100, height: 10)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .redacted(reason: .placeholder)
    }

    // MARK: Loading

    private func load() async {
        let generation = shuffleGeneration
        // Show the last-seen list immediately (works offline); only spin if we have nothing.
        let cached = telegram.cachedChatAudio(chat.id, includeHidden: true)
        if !cached.isEmpty { tracks = cached; isLoading = false } else { isLoading = true }
        defer { isLoading = false }
        do {
            let page = try await telegram.audioMessages(in: chat.id)
            guard generation == shuffleGeneration else { return }
            tracks = page
            nextFromId = page.isEmpty ? nil : page.last?.messageId
            telegram.cacheChatAudio(page, chatId: chat.id)
            error = nil
        } catch {
            // Keep showing the cache when offline; only surface an error if we have nothing.
            if tracks.isEmpty {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Pull-to-refresh: re-fetch the first page from the server without showing skeleton loaders.
    /// Resets pagination so the user starts from the top with fresh data.
    private func refresh() async {
        guard !preparingShuffle else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let page = try await telegram.audioMessages(in: chat.id)
            tracks = page
            nextFromId = page.isEmpty ? nil : page.last?.messageId
            telegram.cacheChatAudio(page, chatId: chat.id)
            error = nil
        } catch {
            // Silently keep the current list — the spinner already communicated "no new data".
            if tracks.isEmpty {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func loadMore() async {
        guard let from = nextFromId, !loadingMore, !preparingShuffle else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await telegram.audioMessages(in: chat.id, fromMessageId: from)
            guard !preparingShuffle, nextFromId == from else { return }
            let existingIds = Set(tracks.map { $0.id })
            let fresh = page.filter { !existingIds.contains($0.id) }
            
            print("NChatAudioView loadMore: fetched \(page.count) tracks, \(fresh.count) fresh ones. fromMessageId was \(from).")
            
            if fresh.isEmpty {
                // If we fetched a full page but all of them are duplicates, TDLib is looping or giving us the same page.
                // Stop the pagination loop.
                nextFromId = nil
            } else {
                tracks.append(contentsOf: fresh)
                nextFromId = page.isEmpty ? nil : page.last?.messageId
            }
        } catch {
            print("NChatAudioView loadMore error: \(error)")
        }
    }

    private func shuffleFullChat() async {
        let alreadyLoaded = telegram.visible(sortedTracks)
        guard !alreadyLoaded.isEmpty else {
            preparingShuffle = false
            return
        }

        // Start from the visible page immediately. The player owns this expansion task so a new
        // queue or shuffle toggle cancels it even if this screen disappears.
        preparingShuffle = false
        player.shufflePlayProgressively(tracks: alreadyLoaded, context: chat.title) { sessionID in
            do {
                let full = try await telegram.allChatAudio(in: chat.id, onPage: { page in
                    _ = player.appendToProgressiveShuffle(telegram.visible(page), sessionID: sessionID)
                })
                try Task.checkCancellation()
                let visibleFull = telegram.visible(full)
                tracks = visibleFull
                nextFromId = nil
                telegram.cacheChatAudio(visibleFull, chatId: chat.id)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                shuffleError = error.localizedDescription
                showShuffleError = true
            }
        }
    }

    private func playFrom(_ track: AudioTrack) {
        guard !telegram.isHidden(track) else { return }
        preparingShuffle = false
        let start = sortedTracks.firstIndex { $0.id == track.id } ?? 0
        player.play(tracks: sortedTracks, startAt: start, context: chat.title)
    }
}
