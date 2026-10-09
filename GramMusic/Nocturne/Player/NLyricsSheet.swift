import SwiftUI

/// Full lyrics retain playback controls while loading the next song's text.
struct NLyricsSheet: View {
    let lyrics: Lyrics?
    let isLoading: Bool
    let track: AudioTrack
    let tint: Color

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text(track.displayTitle).font(.headline)
                    Text(track.displaySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                if let lyrics {
                    NLyricsText(lyrics: lyrics, isPreview: false)
                        .id(lyrics)
                    Text(lyrics.source == .lrclib ? "Lyrics from LRCLIB" : "Lyrics from file")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(12)
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Checking for lyrics…")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No lyrics found", systemImage: "quote.bubble")
                }

                NLyricsTransport()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            .foregroundStyle(.white)
            .background { tint.overlay(.black.opacity(0.6)).ignoresSafeArea() }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: { dismiss() })
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: lyrics) {
            if let lyrics {
                AnalyticsService.logViewLyrics(synced: lyrics.isSynced, source: lyrics.source.rawValue)
            }
        }
    }
}
