import SwiftUI
import SwiftData

/// The Spotify-style "⋯" track menu. Tapping the ellipsis on any `TrackRow` opens this sheet:
/// Add to / Remove from Favorites, Add to Playlist, and Download — the three actions the user
/// reaches most. "Add to Playlist" presents the existing picker as a nested sheet. Pair the
/// ellipsis (`onMore`) with `NTrackContextMenu` so a long-press offers the same actions.
struct NTrackActionsSheet: View {
    let track: AudioTrack
    var showsSourceActions = true
    var fromSearch = false

    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(TelegramService.self) private var telegram
    @Environment(PlayerEngine.self) private var player
    @Environment(NActionFeedback.self) private var feedback: NActionFeedback?

    /// Derived from the shared favourites mirror rather than copied into @State on
    /// appear, which went stale as soon as the track was liked from another surface.
    private var isFavoriteTrack: Bool { telegram.isFavorite(track) }
    @State private var isOnProfile = false
    @State private var showAddToPlaylist = false
    @State private var showReport = false
    @State private var showRemoveDownloadConfirm = false

    private var service: PlaylistService { PlaylistService(context: context) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                Divider().overlay(theme.hairline).padding(.vertical, 8)

                ScrollView {
                    VStack(spacing: 0) {
                        actionRow(isFavoriteTrack ? "heart.fill" : "heart",
                                  isFavoriteTrack ? "Remove from Favorites" : "Add to Favorites",
                                  tint: isFavoriteTrack ? theme.accentColor : theme.text) {
                            if let feedback { feedback.toggleFavorite(track, in: telegram) }
                            else { telegram.toggleFavorite(track) }
                        }
                        actionRow("text.line.first.and.arrowtriangle.forward", "Play Next", enabled: !telegram.isHidden(track)) {
                            player.playNext(track, feedback: feedback, fromSearch: fromSearch)
                            dismiss()
                        }
                        actionRow("text.line.last.and.arrowtriangle.forward", "Add to Queue", enabled: !telegram.isHidden(track)) {
                            player.addToQueue(track, feedback: feedback, fromSearch: fromSearch)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            dismiss()
                        }
                        actionRow("text.badge.plus", "Add to Playlist") { showAddToPlaylist = true }
                        actionRow(isOnProfile ? "music.mic" : "music.mic.circle",
                                  isOnProfile ? "Remove from Profile" : "Add to Profile",
                                  tint: isOnProfile ? theme.accentColor : theme.text) {
                            let nowOn = !isOnProfile
                            withAnimation(.snappy) { isOnProfile = nowOn }
                            Task {
                                if nowOn { await telegram.addToProfile(track) }
                                else { await telegram.removeFromProfile(track) }
                                // Telegram owns this list: re-derive from the freshly synced mirror so a
                                // failed write (offline, flood-wait) snaps back instead of lying.
                                withAnimation(.snappy) { isOnProfile = telegram.isProfileAudio(track) }
                            }
                        }
                        actionRow(telegram.isHidden(track) ? "eye" : "eye.slash",
                                  telegram.isHidden(track) ? "Unhide song" : "Hide song") {
                            if telegram.isHidden(track) { telegram.unhideTrack(track) }
                            else { telegram.hideTracks([track]) }
                            dismiss()
                        }
                        downloadRow
                        if showsSourceActions && telegram.isReportable(track: track) {
                            actionRow("exclamationmark.bubble", "Report message", tint: Color(hex: 0xFF453A)) {
                                showReport = true
                            }
                        }

                    }

                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .background(ScreenBackground())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            // Add/Remove Profile writes to Telegram and can fail; the host screen's banner is
            // behind this sheet, so surface it here.
            .playbackErrorBanner()
            .actionFeedback()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showAddToPlaylist) { NAddToPlaylistSheet(track: track) }
        .sheet(isPresented: $showReport) { NReportSheet(chatId: track.chatId, messageIds: [track.messageId], onDismiss: { showReport = false }) }
        .alert("Remove Download?", isPresented: $showRemoveDownloadConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                telegram.removeDownload(track)
                dismiss()
            }
        } message: {
            Text("This track was deleted from Telegram. If you remove the downloaded file, you won't be able to play or download it again.")
        }
        .onAppear {
            isOnProfile = telegram.isProfileAudio(track)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TrackArtwork(track: track, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle).font(.headline)
                    .foregroundStyle(theme.text).lineLimit(1)
                Text(track.displaySubtitle).font(.subheadline)
                    .foregroundStyle(theme.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var downloadRow: some View {
        if let fraction = telegram.downloadFraction(for: track) {
            HStack(spacing: 14) {
                DownloadRing(progress: fraction).frame(width: 22, height: 22).frame(width: 26)
                Text("Downloading… \(Int(fraction * 100))%").font(.system(size: 16)).foregroundStyle(theme.text2)
                Spacer(minLength: 0)
            }
            .frame(height: 52)
        } else if telegram.isDownloaded(track) {
            actionRow("trash", "Remove download", tint: Color(hex: 0xFF453A)) {
                if telegram.isUnavailableOnTelegram(track) {
                    showRemoveDownloadConfirm = true
                } else {
                    telegram.removeDownload(track)
                    dismiss()
                }
            }
        } else {
            actionRow("arrow.down.circle", "Download") {
                telegram.download(track)
                dismiss()
            }
        }
    }

    private func actionRow(_ systemName: String, _ title: String,
                           tint: Color? = nil, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName).font(.system(size: 18))
                    .foregroundStyle(tint ?? theme.text).frame(width: 26)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.body).foregroundStyle(tint ?? theme.text)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Long-press parity for `NTrackActionsSheet` — drop into `.contextMenu { NTrackContextMenu(...) }`.
/// `onAddToPlaylist` lets the host present its own `NAddToPlaylistSheet` (context menus can't
/// present sheets themselves).
struct NTrackContextMenu: View {
    let track: AudioTrack
    var onAddToPlaylist: () -> Void
    var onReport: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(TelegramService.self) private var telegram
    @Environment(PlayerEngine.self) private var player
    @Environment(NActionFeedback.self) private var feedback: NActionFeedback?

    private var service: PlaylistService { PlaylistService(context: context) }

    var body: some View {
        let favorite = telegram.isFavorite(track)
        Button {
            if let feedback { feedback.toggleFavorite(track, in: telegram) }
            else { telegram.toggleFavorite(track) }
        } label: {
            Label(favorite ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: favorite ? "heart.fill" : "heart")
        }
        Button { player.playNext(track, feedback: feedback) } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button { player.addToQueue(track, feedback: feedback) } label: {
            Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Button(action: onAddToPlaylist) {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        let onProfile = telegram.isProfileAudio(track)
        Button {
            Task { onProfile ? await telegram.removeFromProfile(track) : await telegram.addToProfile(track) }
        } label: {
            Label(onProfile ? "Remove from Profile" : "Add to Profile",
                  systemImage: onProfile ? "music.mic" : "music.mic.circle")
        }
        if telegram.isDownloaded(track) {
            Button(role: .destructive) { telegram.removeDownload(track) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else if let fraction = telegram.downloadFraction(for: track) {
            Label("Downloading… \(Int(fraction * 100))%", systemImage: "arrow.down.circle.dotted")
        } else {
            Button { telegram.download(track) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        Button {
            if telegram.isHidden(track) { telegram.unhideTrack(track) }
            else { telegram.hideTracks([track]) }
        } label: {
            Label(telegram.isHidden(track) ? "Unhide song" : "Hide song",
                  systemImage: telegram.isHidden(track) ? "eye" : "eye.slash")
        }
        if onReport != nil && telegram.isReportable(track: track) {
            Button(role: .destructive, action: { onReport?() }) {
                Label("Report message", systemImage: "exclamationmark.bubble")
            }
        }

    }
}
