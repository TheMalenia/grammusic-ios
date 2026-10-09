import SwiftUI
import SwiftData

/// Results retain the same track rows and Telegram entity groups across source tabs.
struct NSearchResultsView: View {
    let songs: [AudioTrack]
    let query: String
    let source: MusicSearchSource
    let scope: NSearchView.Scope
    let localContext: String?
    let controller: MusicSearchController
    let onCommit: () -> Void
    let onRetry: () -> Void
    let onLoadMore: () async -> Void
    let onSearchTelegram: () -> Void
    @Binding var addTarget: AudioTrack?
    @Binding var actionTarget: AudioTrack?
    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    @Query private var playlists: [Playlist]

    var body: some View {
        if let localContext {
            List {
                ForEach(songs) { track in
                    NSearchTrackRow(track: track, songs: songs, context: localContext,
                                    onCommit: onCommit, addTarget: $addTarget,
                                    actionTarget: $actionTarget)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if songs.isEmpty {
                    Text(query.isEmpty ? "Nothing here yet." : "No results for “\(query)”")
                        .foregroundStyle(theme.text2).padding(.top, 60)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .modifier(NScrollDockViewport())
        } else {
            results
        }
    }

    private var status: some View {
        VStack(spacing: 10) {
            if controller.isSearching {
                ProgressView().tint(theme.accentColor)
                Text("Searching \(source.label)…")
            } else if let failure = controller.failure {
                Image(systemName: "exclamationmark.bubble").font(.title2)
                Text(failure.title).font(.headline).foregroundStyle(theme.text)
                Text(failure.message).multilineTextAlignment(.center)
                if failure.canRetry {
                    Button(failure.isPagination ? "Retry loading" : "Try again") {
                        if failure.isPagination { Task { await onLoadMore() } }
                        else { onRetry() }
                    }
                    .buttonStyle(.bordered).tint(theme.accentColor)
                }
                if !source.isTelegram {
                    Button("Search Telegram instead", action: onSearchTelegram)
                }
            } else {
                Text("No results for “\(query)”").font(.headline).foregroundStyle(theme.text)
                if !source.isTelegram && controller.nonAudioResultCount > 0 {
                    Text("\(source.label) replied, but this page has no playable audio. Try another search or choose a different source.")
                } else if telegram.isOfflineStable {
                    Text("You're offline. Search currently includes only music saved on this device.")
                } else {
                    Text("Try a song title, an artist name, or a different spelling.")
                }
            }
        }
        .font(.system(size: 14)).foregroundStyle(theme.text2)
        .frame(maxWidth: .infinity).padding(.top, 40)
        .accessibilityElement(children: .contain)
    }

    // MARK: Results

    /// Artists worth offering for the query: the performers in the song results, plus the artists
    /// the user already follows (which no message search would surface, and which are the ones
    /// they most likely mean).
    private var artistResults: [String] {
        let fromSongs = AudioSearch.artists(in: songs, query: query)
        let followed = (source.isTelegram ? telegram.followedArtists : []).filter { AudioSearch.matches($0, query: query) }
        var seen = Set<String>()
        return (followed + fromSongs)
            .filter { seen.insert(AudioSearch.fold($0)).inserted }
            .prefix(8)
            .map { $0 }
    }

    @ViewBuilder private var results: some View {
        let showSongs = !source.isTelegram || scope == .all || scope == .songs
        let showArtists = source.isTelegram && (scope == .all || scope == .artists)
        let showPlaylists = source.isTelegram && (scope == .all || scope == .playlists)
        let showChats = source.isTelegram && (scope == .all || scope == .chats)
        // Chats and profiles are both "places", so the Chats chip covers them — before, the
        // Profiles group ignored the chip entirely and showed under every filter.
        let chats = showChats ? telegram.chats.filter { AudioSearch.matches($0.title, query: query) } : []
        let pls = showPlaylists ? playlists.sortedForLibrary.filter { AudioSearch.matches($0.name, query: query) } : []
        let profs = showChats ? telegram.userProfiles.filter {
            AudioSearch.matches($0.title, query: query) || AudioSearch.matches($0.userName, query: query)
        } : []
        let artists = showArtists ? artistResults : []
        let songs = showSongs ? self.songs : []
        List {
            if !songs.isEmpty {
                group("Songs") {
                    ForEach(songs) { t in
                        NSearchTrackRow(track: t, songs: songs, context: "Search · " + source.label,
                                        onCommit: onCommit, addTarget: $addTarget,
                                        actionTarget: $actionTarget)
                    }
                }
            }
            if !artists.isEmpty {
                group("Artists") {
                    ForEach(artists, id: \.self) { name in
                        NavigationLink(value: Artist(name: name)) {
                            NListRow(seed: name, title: name, subtitle: "Artist", kind: .artist)
                        }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { onCommit() })
                    }
                }
            }
            if !pls.isEmpty {
                group("Playlists") {
                    ForEach(pls) { p in
                        NavigationLink(value: p) {
                            NListRow(seed: p.name, title: p.name, subtitle: "\(p.trackCount) tracks",
                                     playlist: p.isSmart ? nil : p,
                                     smart: p.isSmart, smartSymbol: p.symbolName)
                        }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { onCommit() })
                    }
                }
            }
            if !chats.isEmpty {
                group("Chats") {
                    ForEach(chats) { c in
                        NavigationLink(value: c) {
                            NListRow(seed: c.title, title: c.title, subtitle: c.audioMeta, kind: .chat)
                        }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { onCommit() })
                    }
                }
            }
            if !profs.isEmpty {
                group("Profiles") {
                    ForEach(profs) { p in
                        NavigationLink(value: p) {
                            NListRow(seed: p.userName, title: p.title, subtitle: "Profile · \(p.trackCount) tracks", data: p.photoData, kind: .chat)
                        }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { onCommit() })
                    }
                }
            }
            let nothing = songs.isEmpty && artists.isEmpty && pls.isEmpty && chats.isEmpty && profs.isEmpty
            if nothing || controller.error != nil {
                status.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if !controller.nextOffset.isEmpty && controller.failure == nil {
                if source.isTelegram {
                    Button { Task { await onLoadMore() } } label: {
                        HStack(spacing: 8) {
                            Text(controller.isLoadingMore ? "Loading…" : "Load more songs")
                            if controller.isLoadingMore { ProgressView().tint(theme.accentColor) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .foregroundStyle(theme.accentColor)
                    .disabled(controller.isLoadingMore)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ProgressView().tint(theme.accentColor)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .task(id: "\(source.requestKey)|\(query)|\(controller.nextOffset)") {
                            await onLoadMore()
                        }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listRowSpacing(0)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.top, 0, for: .scrollContent)
        .modifier(NScrollDockViewport())
        .scrollDismissesKeyboard(.immediately)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        Group {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.text2)
                .accessibilityAddTraits(.isHeader)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            c()
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

}
