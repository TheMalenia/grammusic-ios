import SwiftUI

/// Shared destination row for the like-button and multi-track playlist pickers.
struct NPlaylistPickerRow: View {
    let playlist: Playlist
    var isAdded = false
    var isAdding = false
    var addingSelection = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            NPlaylistCover(playlist: playlist, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).foregroundStyle(theme.text).lineLimit(1)
                if isAdding && addingSelection {
                    Text("Adding to playlist…").font(.subheadline).foregroundStyle(theme.accentColor)
                } else {
                    Text("\(playlist.trackCount) tracks").font(.subheadline).foregroundStyle(theme.text2)
                }
            }
            Spacer()
            if isAdding { AddBadge(state: .adding, size: 22) }
            else {
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3).foregroundStyle(isAdded ? theme.accentColor : theme.text3)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
