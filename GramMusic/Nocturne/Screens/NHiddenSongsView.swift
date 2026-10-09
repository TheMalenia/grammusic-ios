import SwiftUI

struct NHiddenSongsView: View {
    @Environment(TelegramService.self) private var telegram
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(telegram.hiddenTracks.tracks) { track in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.displayTitle).font(.body).foregroundStyle(theme.text)
                            Text(track.displaySubtitle).font(.subheadline).foregroundStyle(theme.text2)
                        }
                        Spacer()
                        Button("Unhide") { telegram.unhideTrack(track) }
                            .frame(minHeight: 44)
                            .accessibilityLabel("Unhide \(track.displayTitle)")
                    }
                    .listRowBackground(Color.clear)
                    .swipeActions {
                        Button("Unhide", systemImage: "eye") { telegram.unhideTrack(track) }
                            .tint(theme.accentColor)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if telegram.hiddenTracks.tracks.isEmpty {
                    ContentUnavailableView("No hidden songs", systemImage: "eye",
                                           description: Text("Songs you hide will appear here. Unhide them to allow playback again."))
                }
            }
            .background(ScreenBackground())
            .navigationTitle("Hidden songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
