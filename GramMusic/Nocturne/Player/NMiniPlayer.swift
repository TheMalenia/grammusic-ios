import SwiftUI

/// Nocturne mini-player (screens §10). Docked above the tab bar whenever audio is loaded;
/// tap anywhere but the controls → expand to Now Playing. A thin accent progress line is
/// pinned to the bottom edge. Swipe left for the next track, right for the previous action.
struct NMiniPlayer: View {
    @Environment(\.theme) private var theme
    @Environment(PlayerEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ScaledMetric(relativeTo: .subheadline) private var infoHeight = 46.0
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeWidth: CGFloat = 200
    @State private var swipeDirection: CGFloat = -1
    @State private var swipePreview: AudioTrack?
    @State private var isDragging = false
    @State private var isSettling = false
    @State private var isSwipeArmed = false
    @State private var swipeToken = UUID()

    var isCompact = false
    var usesSystemBackground = false
    var onExpand: () -> Void = {}

    var body: some View {
        if let track = player.current {
            let shape = Capsule(style: .continuous)
            HStack(spacing: 10) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    ZStack(alignment: .leading) {
                        MiniTrackInfo(track: track, isCompact: isCompact)
                            .offset(x: reduceMotion ? 0 : swipeOffset)
                            .opacity(reduceMotion && isDragging ? 0.65 : 1)

                        if isDragging || isSettling, !reduceMotion {
                            Group {
                                if let swipePreview {
                                    MiniTrackInfo(track: swipePreview, isCompact: isCompact)
                                } else {
                                    // Autoplay chooses its next song asynchronously.
                                    Label("Next track", systemImage: "forward.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(theme.text2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .offset(x: swipeOffset - swipeDirection * (width + 16))
                            .accessibilityHidden(true)
                        }
                    }
                    .frame(width: width, height: geometry.size.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isDragging, !isSettling else { return }
                        onExpand()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(track.displayTitle), \(track.displaySubtitle)")
                    .accessibilityHint("Opens the full player")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Next track") {
                        if player.hasNext { player.next() }
                    }
                    .accessibilityAction(named: "Previous track") {
                        player.previous()
                    }
                    .onChange(of: width, initial: true) { _, width in
                        swipeWidth = width
                    }
                }
                .frame(height: infoHeight)

                NMiniControls(isCompact: isCompact)
            }
            .padding(.horizontal, 12)
            .frame(height: isCompact ? max(44, infoHeight) : infoHeight + 16)
            .background {
                // Keep playhead updates isolated from the artwork, titles and gesture state.
                if !isCompact {
                    MiniProgressLine()
                        .padding(.horizontal, 30)
                        .allowsHitTesting(false)
                }
            }
            .background {
                if !usesSystemBackground {
                    Color.clear.nocturneGlass(shape, theme: theme, elevated: true)
                }
            }
            .contentShape(shape)
            .simultaneousGesture(swipeGesture(width: swipeWidth))
            .sensoryFeedback(.selection, trigger: isSwipeArmed) { _, armed in armed }
            .onChange(of: player.current?.id) { resetSwipe() }
            .onChange(of: player.currentIndex) { resetSwipe() }
            .onDisappear { resetSwipe() }
        }
    }

    private func swipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isSettling else { return }
                let horizontal = value.translation.width
                guard abs(horizontal) > abs(value.translation.height) * 1.5 else { return }
                let direction: CGFloat = horizontal < 0 ? -1 : 1
                if !isDragging || direction != swipeDirection {
                    swipePreview = player.skipPreview(forward: direction < 0)
                    swipeDirection = direction
                }
                isDragging = true
                let canSkip = direction > 0 || player.hasNext
                // At the end of the queue, give gentle resistance instead of a blank page.
                swipeOffset = canSkip ? max(-width, min(width, horizontal)) : horizontal * 0.18
                isSwipeArmed = canSkip && abs(horizontal) >= swipeThreshold(width: width)
            }
            .onEnded { value in
                finishSwipe(value, width: width)
            }
    }

    private func swipeThreshold(width: CGFloat) -> CGFloat {
        max(44, min(72, width * 0.3))
    }

    private func finishSwipe(_ value: DragGesture.Value, width: CGFloat) {
        guard isDragging, !isSettling else { return }
        let horizontal = value.translation.width
        let forward = horizontal < 0
        let threshold = swipeThreshold(width: width)
        let isHorizontal = abs(horizontal) > abs(value.translation.height) * 1.5
        let isFlick = abs(horizontal) >= 20
            && abs(value.predictedEndTranslation.width) >= threshold * 2
            && value.predictedEndTranslation.width * horizontal > 0
        let shouldSkip = isHorizontal && (abs(horizontal) >= threshold || isFlick)
            && (!forward || player.hasNext)
        isSettling = true
        isSwipeArmed = false
        let token = swipeToken

        guard shouldSkip else {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
                swipeOffset = 0
            } completion: {
                guard swipeToken == token else { return }
                resetSwipe()
            }
            return
        }

        swipeDirection = forward ? -1 : 1
        swipePreview = player.skipPreview(forward: forward)
        // Finish the carousel before replacing its current song, avoiding a title flash.
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            swipeOffset = swipeDirection * (width + 16)
        } completion: {
            guard swipeToken == token else { return }
            resetSwipe()
            if forward {
                if player.hasNext { player.next() }
            } else {
                player.previous()
            }
        }
    }

    private func resetSwipe() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            swipeToken = UUID()
            swipeOffset = 0
            swipePreview = nil
            isDragging = false
            isSettling = false
            isSwipeArmed = false
        }
    }
}

/// The same artwork and typography on both pages of the mini-player's swipe carousel.
private struct MiniTrackInfo: View {
    @Environment(\.theme) private var theme
    let track: AudioTrack
    var isCompact = false

    var body: some View {
        HStack(spacing: isCompact ? 6 : 10) {
            TrackArtwork(track: track, size: isCompact ? 30 : 38)
            VStack(alignment: .leading, spacing: 1) {
                NMarqueeText {
                    Text(track.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.text)
                }
                if !isCompact {
                    NMarqueeText {
                        Text(track.displaySubtitle)
                            .font(.caption)
                            .foregroundStyle(theme.text2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The thin accent progress line under the mini-player. Isolated so that the twice-a-second
/// `currentTime` update invalidates only these two pixels of capsule, not the whole bar.
private struct MiniProgressLine: View {
    @Environment(\.theme) private var theme
    @Environment(PlayerEngine.self) private var player

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(max(player.currentTime / player.duration, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(theme.accentColor)
                .frame(width: max(geo.size.width * progress, 2), height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .animation(.linear(duration: 0.5), value: progress)
        }
    }
}

/// The mini-player transport (play/pause · next · stop), factored out for reuse.
struct NMiniControls: View {
    @Environment(\.theme) private var theme
    @Environment(PlayerEngine.self) private var player
    var isCompact = false
    var showsStop = true

    var body: some View {
        HStack(spacing: 2) {
            if player.isLoading {
                ProgressView()
                    .tint(theme.accentColor)
                    .frame(width: 44, height: 44)
            } else {
                IconButton(systemName: player.isPlaying ? "pause.fill" : "play.fill",
                           size: 20, color: theme.text) {
                    player.togglePlayPause()
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }

            if !isCompact {
                IconButton(systemName: "forward.fill", size: 19, color: theme.text) {
                    player.next()
                }
                .frame(width: 44, height: 44)
                .disabled(!player.hasNext)
                .opacity(player.hasNext ? 1 : 0.4)
                .accessibilityLabel("Next track")
            }

            if showsStop && !isCompact {
                IconButton(systemName: "xmark", size: 15, color: theme.text2) {
                    // Explicit animation so the bar slides down on close (see the dock's transition).
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { player.stop() }
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel("Stop playback")
                .accessibilityIdentifier("miniPlayer.close")
            }
        }
    }
}
