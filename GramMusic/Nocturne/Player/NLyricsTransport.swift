import SwiftUI

/// A small playback strip so listeners do not need to close the full lyrics to control music.
struct NLyricsTransport: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(spacing: 8) {
            Scrubber(currentTime: player.currentTime, duration: player.duration,
                     bufferedTime: player.bufferedTime, overArt: true,
                     onSeek: { player.seek(to: $0) })
            HStack(spacing: 40) {
                Button("Previous track", systemImage: "backward.fill", action: player.previous)
                    .frame(width: 44, height: 44)
                Button(player.isPlaying ? "Pause" : "Play",
                       systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                       action: player.togglePlayPause)
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.15), in: Circle())
                Button("Next track", systemImage: "forward.fill", action: player.next)
                    .frame(width: 44, height: 44)
                    .disabled(!player.hasNext)
                    .opacity(player.hasNext ? 1 : 0.4)
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
    }
}
