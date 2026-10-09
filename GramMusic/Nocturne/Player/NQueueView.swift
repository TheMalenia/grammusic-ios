import SwiftUI

/// Up-next queue (screens §11). A "Now Playing" row (accent title + Equalizer) on top,
/// then a draggable "NEXT UP" section of the upcoming tracks: tap to jump, drag to
/// reorder, tap the red minus to remove.
struct NQueueView: View {
    @Environment(\.theme) private var theme
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    /// Upcoming slots (after the current track), split by origin so manual "Add to Queue"
    /// items show under "Next in Queue" and the rest under "Next from <context>".
    private var upcoming: [(index: Int, entry: QueueEntry)] {
        let start = player.currentIndex + 1
        let all = player.entries
        guard start < all.count else { return [] }
        return (start..<all.count).map { (index: $0, entry: all[$0]) }
    }
    /// Both were computed properties read three times each per body — six full rebuilds of
    /// `upcoming` (copying every QueueEntry, each holding an AudioTrack) per render.
    private var split: (manual: [(index: Int, entry: QueueEntry)],
                        context: [(index: Int, entry: QueueEntry)]) {
        var manual: [(index: Int, entry: QueueEntry)] = []
        var context: [(index: Int, entry: QueueEntry)] = []
        for slot in upcoming {
            if slot.entry.origin == .userQueue { manual.append(slot) } else { context.append(slot) }
        }
        return (manual, context)
    }

    var body: some View {
        let split = split
        let manualUpcoming = split.manual
        let contextUpcoming = split.context
        return NavigationStack {
            List {
                if let current = player.current {
                    Section {
                        nowPlayingRow(current)
                            .listRowBackground(theme.accentColor.opacity(0.14))
                            .listRowSeparator(.hidden)
                    } header: {
                        Text(player.contextName.map { "Playing from \($0)" } ?? "Playing now")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(theme.text3)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                    }
                }

                if !manualUpcoming.isEmpty {
                    Section {
                        // Key rows by slot identity (not index) so a reorder animates the row
                        // *moving* rather than swapping each slot's content in place.
                        ForEach(manualUpcoming, id: \.entry.id) { item in
                            upNextRow(item.entry.track, at: item.index)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .deleteDisabled(true)
                        }
                        .onMove { source, dest in move(manualUpcoming.map(\.index), source, dest) }
                    } header: {
                        sectionHeader("NEXT IN QUEUE")
                    }
                }

                Section {
                    if contextUpcoming.isEmpty {
                        Text("End of queue.")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text3)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(contextUpcoming, id: \.entry.id) { item in
                            upNextRow(item.entry.track, at: item.index)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .deleteDisabled(true)
                        }
                        .onMove { source, dest in move(contextUpcoming.map(\.index), source, dest) }
                    }
                } header: {
                    sectionHeader(player.contextName.map { "NEXT FROM \($0.uppercased())" } ?? "NEXT UP")
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(.compact)
            .scrollContentBackground(.hidden)
            .background(ScreenBackground())
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.text2)
                    }
                    .accessibilityLabel("Close queue")
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(theme.bg)
    }

    private func nowPlayingRow(_ track: AudioTrack) -> some View {
        HStack(spacing: 12) {
            TrackArtwork(track: track, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.headline)
                    .foregroundStyle(theme.accentColor)
                    .lineLimit(1)
                Text(track.displaySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Equalizer(playing: player.isPlaying)
                .frame(width: 18)
        }
        .padding(.vertical, 6)
    }

    private func upNextRow(_ track: AudioTrack, at index: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                player.removeFromQueue(at: IndexSet(integer: index))
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel("Remove \(track.displayTitle) from queue")

            Button {
                player.jump(to: index)
            } label: {
                HStack(spacing: 12) {
                    TrackArtwork(track: track, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.displayTitle)
                            .font(.body.weight(.medium))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Text(track.displaySubtitle)
                            .font(.subheadline)
                            .foregroundStyle(theme.text2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(theme.text3)
    }

    /// `.onMove` offsets are relative to one section; `indices` maps each section row to its
    /// absolute index in `player.queueEntries`. Translate, then reorder the backing queue.
    private func move(_ indices: [Int], _ source: IndexSet, _ destination: Int) {
        let absSource = IndexSet(source.map { indices[$0] })
        // SwiftUI's `destination` is an insertion point within the section (0...count).
        let absDest: Int
        if destination < indices.count {
            absDest = indices[destination]
        } else if let last = indices.last {
            absDest = last + 1
        } else {
            absDest = player.currentIndex + 1
        }
        player.moveInQueue(from: absSource, to: absDest)
    }
}
