import SwiftUI

/// A full, vertically browsable version of a Home listening shelf.
struct NTrackShelfView: View {
    let title: String
    let tracks: [AudioTrack]
    @Environment(PlayerEngine.self) private var player
    @Environment(TelegramService.self) private var telegram
    @Environment(NActionFeedback.self) private var feedback
    @Environment(\.theme) private var theme
    @State private var actionTarget: AudioTrack?

    var body: some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(title: track.displayTitle, subtitle: track.displaySubtitle,
                         seed: track.remoteUniqueId, track: track,
                         isActive: player.current?.remoteUniqueId == track.remoteUniqueId,
                         isPlaying: player.isPlaying, downloaded: telegram.isDownloaded(track),
                         duration: track.formattedDuration, verticalPadding: 4,
                         onTap: { player.play(tracks: tracks, startAt: index, context: title) },
                         onMore: { actionTarget = track })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .swipeActions(edge: .leading) {
                        Button { feedback.enqueue(track, in: player) } label: {
                            Label("Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                        }
                        .tint(theme.accentColor)
                    }
            }
        }
        .listStyle(.plain)
        .modifier(NScrollDockViewport(base: 16))
        .scrollContentBackground(.hidden)
        .background(ScreenBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(item: $actionTarget) { track in NTrackActionsSheet(track: track) }
    }
}
