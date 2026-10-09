import SwiftUI

/// The core list row (Components §TrackRow). Number-style (playlists) when `index` is set,
/// else artwork-style. Marks the active track with an Equalizer. Purely presentational —
/// screens attach `.swipeActions` / `.contextMenu` and supply `onTap` / `onMore`.
struct TrackRow: View {
    @Environment(\.theme) private var theme
    /// Optional so the row still renders in previews / contexts without the service injected.
    @Environment(TelegramService.self) private var telegram: TelegramService?

    @Environment(NTrackSelection.self) private var selection: NTrackSelection?
    @Environment(\.editMode) private var editMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selecting: Bool { selection?.isSelecting == true }
    private var selected: Bool { track.map { selection?.contains($0) == true } ?? false }
    private var canSelect: Bool { selection != nil && track != nil && editMode?.wrappedValue != .active }

    private func tap() {
        if selecting, let track { selection?.toggle(track) }
        else if !unavailableOffline { onTap() }
    }

    var title: String
    var subtitle: String
    var seed: String
    var artworkData: Data? = nil
    /// When set, the artwork-style row resolves the track's hi-res cover on demand (the embedded
    /// `artworkData` minithumbnail is tiny and blurry). Number-style rows ignore it.
    var track: AudioTrack? = nil
    var index: Int? = nil
    var isActive: Bool = false
    var isPlaying: Bool = false
    /// Explicit override for the heart. Normally left `nil`, in which case the row derives it from
    /// the shared favourites mirror — no call site ever passed this, so the heart used to never
    /// appear in any list, even for favourited tracks.
    var liked: Bool? = nil
    var downloaded: Bool = false
    /// Explicit override for the download ring. Normally left `nil`: the row resolves the live
    /// fraction inside a leaf view instead, because reading it in the *parent's* body made every
    /// TDLib progress tick re-render the entire list rather than the one downloading row.
    var downloadProgress: Double? = nil
    var duration: String = ""
    var verticalPadding: CGFloat = 8
    var onTap: () -> Void = {}
    var onMore: (() -> Void)? = nil
    /// When set, the row gets a Spotify-style horizontal swipe revealing an "Add to Queue"
    /// affordance. Used on screens that render rows in a `LazyVStack` (where `.swipeActions`
    /// — which only works inside `List` — is inert).
    var onAddToQueue: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil

    /// A container AVFoundation can't decode yet (Opus/Ogg). The row stays tappable — tapping
    /// surfaces the "not supported yet" notice — but is dimmed and marked so it's not a surprise.
    private var unsupported: Bool { track?.isLikelyUnsupported ?? false }

    /// Offline and no local file → can't stream, so the row is greyed out and not tappable
    /// (only locally-available tracks stay playable, Spotify-style). `.updating`/`.ready` are online.
    ///
    /// Asks `isAvailableOffline`, **not** the `downloaded` flag. That flag answers "did the user
    /// download this", which is the right question for the checkmark and the wrong one here: a
    /// *cached* track is a real file that plays with no network, and keying availability off
    /// `downloaded` greyed out — and made untappable — every track the app had cached from
    /// playing it.
    private var unavailableOffline: Bool {
        guard telegram?.isOfflineStable ?? false else { return false }
        if downloaded { return false }
        guard let track, let telegram else { return true }
        return !telegram.isAvailableOffline(track)
    }

    /// Whether to show the heart: the explicit override if given, else the shared favourites set.
    private var isLiked: Bool {
        if let liked { return liked }
        guard let track else { return false }
        return telegram?.isFavorite(track) ?? false
    }

    /// Track was deleted on Telegram and is not downloaded locally.
    private var isDeletedOnTelegram: Bool {
        guard let track, !downloaded else { return false }
        return telegram?.isUnavailableOnTelegram(track) ?? false
    }

    var body: some View {
        let row = HStack(spacing: 12) {
            Button(action: tap) {
                HStack(spacing: 12) {
                    if selecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2).foregroundStyle(selected ? theme.accentColor : theme.text3)
                            .frame(width: 26)
                            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                            .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                    leading
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isActive ? theme.accentColor : theme.text)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if unavailableOffline {
                                Image(systemName: "icloud.slash").font(.system(size: 12)).foregroundStyle(theme.text3)
                            } else if isDeletedOnTelegram {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(theme.text3)
                            } else if unsupported {
                                Image(systemName: "waveform.slash").font(.system(size: 12)).foregroundStyle(theme.text3)
                            } else if downloaded {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.text3)
                            }
                            Text(isDeletedOnTelegram ? "Deleted on Telegram" : (unsupported ? "Unsupported format" : subtitle))
                                .font(.subheadline).foregroundStyle(theme.text2).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .opacity(unavailableOffline ? 0.4 : (isDeletedOnTelegram ? 0.6 : (unsupported ? 0.55 : 1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(unavailableOffline && !canSelect)
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                if canSelect, let track { selection?.begin(track) }
            }, including: canSelect ? .all : .none)
            .accessibilityAction(named: Text("Select track")) {
                if canSelect, let track { selection?.begin(track) }
            }
            .accessibilityValue(selecting ? (selected ? "Selected" : "Not selected") : (isActive ? (isPlaying ? "Playing" : "Paused") : ""))

            if !selecting {
                trailing.opacity(unavailableOffline ? 0.4 : 1)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, verticalPadding)

        // The swipe wraps the row, so it sits *outside* the `.disabled(unavailableOffline)` on the
        // tap target — which meant a greyed-out, un-tappable row could still be swiped into the
        // queue while offline. It then couldn't play, and the player had to skip over it. Gate the
        // gesture on the same conditions as the tap.
        SwipeToQueue(action: { onAddToQueue?() },
                     enabled: onAddToQueue != nil && !selecting && !unavailableOffline && !isDeletedOnTelegram) {
            row
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: selecting)
    }

    @ViewBuilder private var leading: some View {
        if let index {
            ZStack {
                if isActive {
                    Equalizer(playing: isPlaying)
                } else {
                    Text("\(index)").font(.system(size: 15).monospacedDigit()).foregroundStyle(theme.text3)
                }
            }
            .frame(width: 26)
        } else {
            Group {
                if let track {
                    TrackArtwork(track: track, size: 46)
                } else {
                    Artwork(data: artworkData, seed: seed, size: 46)
                }
            }
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.45))
                        Equalizer(playing: isPlaying, color: .white)
                    }
                }
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 10) {
            if isLiked { Image(systemName: "heart.fill").font(.system(size: 15)).foregroundStyle(theme.accentColor) }
            if let downloadProgress {
                DownloadRing(progress: downloadProgress).frame(width: 18, height: 18)
            } else if let track {
                TrackDownloadRing(track: track)
            }
            if !duration.isEmpty {
                Text(duration).font(.caption.monospacedDigit()).foregroundStyle(theme.text3)
            }
            if let onAddToPlaylist {
                Button(action: onAddToPlaylist) {
                    Image(systemName: "plus.circle").font(.system(size: 18))
                        .foregroundStyle(theme.text3).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(title) to playlist")
            }
            if let onMore {
                Button(action: onMore) {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.text3).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More actions for \(title)")
            }
        }
    }
}

/// Reads the live download fraction for one track. Isolated so TDLib's per-chunk progress updates
/// (tens per second, per file) invalidate just this ring instead of every row on screen.
struct TrackDownloadRing: View {
    @Environment(TelegramService.self) private var telegram: TelegramService?
    let track: AudioTrack

    var body: some View {
        if let fraction = telegram?.downloadFraction(for: track) {
            DownloadRing(progress: fraction).frame(width: 18, height: 18)
        }
    }
}

/// Spotify-style determinate download indicator: a faint ring that fills with the accent as the
/// track downloads, with a small square core. `progress` is 0…1; clamp before passing.
struct DownloadRing: View {
    @Environment(\.theme) private var theme
    var progress: Double
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(theme.text3.opacity(0.35), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(theme.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(theme.accentColor)
                .frame(width: lineWidth * 1.6, height: lineWidth * 1.6)
        }
        .animation(.easeOut(duration: 0.25), value: progress)
        .accessibilityLabel("Downloading")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

/// Swipe-to-queue for rows that live in a plain `LazyVStack` (Artist / Chat detail), where
/// `List`'s `.swipeActions` is inert. Mirrors the native leading swipe used on the List-based
/// screens: drag the row to the **right**, an accent panel with a white "Queue" icon is revealed
/// from the leading edge, and past the threshold `action` fires (with haptics) and the row
/// springs back. The drag is `simultaneousGesture` so a tap still reaches the play button and
/// vertical drags still scroll (it only engages once movement is clearly horizontal & rightward).
private struct SwipeToQueue<Content: View>: View {
    @Environment(\.theme) private var theme
    let action: () -> Void
    var enabled = true
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var armedHaptic = false
    /// Past this drag distance the action commits on release.
    private let threshold: CGFloat = 96

    private var committed: Bool { offset >= threshold }

    var body: some View {
        ZStack(alignment: .leading) {
            // Accent action panel, leading edge, width tracking the drag (like a native swipe).
            theme.accentColor
                .frame(width: max(0, offset))
                .overlay {
                    VStack(spacing: 3) {
                        Image(systemName: "text.line.last.and.arrowtriangle.forward")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Queue").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 72)
                    .opacity(min(1.0, offset / 44.0))
                }
                .clipped()

            content
                // Opaque only while swiping so the panel doesn't show *through* the row; at rest
                // the row stays transparent over the screen background.
                .background(offset > 0 ? theme.bg : Color.clear)
                .offset(x: max(0, offset))
        }
        .clipped()
        .simultaneousGesture(drag, including: enabled ? .all : .subviews)
        .onChange(of: enabled) { _, enabled in
            if !enabled { offset = 0; armedHaptic = false }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                // Engage only for a clearly horizontal, rightward drag; otherwise leave it to
                // the scroll view / the row's tap.
                guard enabled, abs(value.translation.width) > abs(value.translation.height),
                      value.translation.width > 0 else { return }
                offset = value.translation.width
                if committed, !armedHaptic {
                    armedHaptic = true
                    UISelectionFeedbackGenerator().selectionChanged()
                } else if !committed {
                    armedHaptic = false
                }
            }
            .onEnded { _ in
                if enabled && committed {
                    action()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                armedHaptic = false
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { offset = 0 }
            }
    }
}
