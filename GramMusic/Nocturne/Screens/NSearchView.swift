import SwiftUI

/// Global search is a persistent root tab; local searches push within the current tab.
/// Empty query → recent searches; with query → grouped Songs / Artists / Chats / Playlists.
///
/// `MusicSearchController` owns requests and tab caches. Telegram/local matching uses
/// `AudioSearch`; bot results preserve the bot's order and collapse duplicate audio.
struct NSearchView: View {
    /// Optional local scope: when set, the screen searches **only** these tracks (a playlist's
    /// or a chat's songs), entirely on-device — no network, no scope picker, no recents.
    /// `nil` = the global search (songs/artists/chats/playlists).
    var localScope: LocalScope? = nil
    /// Embedded global search retains its state in the root TabView.
    var isTab = false
    var embeddedInNavigation = false
    var sharedInput: NSearchInput? = nil
    var onClose: (() -> Void)? = nil

    private var usesNativeSearch: Bool {
        if #available(iOS 26.1, *) { return isTab && usesNativePlayerAccessory }
        return false
    }

    struct LocalScope {
        var title: String
        var tracks: [AudioTrack]
        var context: String   // play context label
        var loadAll: TrackCollectionLoader? = nil
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.nUsesNativePlayerAccessory) private var usesNativePlayerAccessory
    @Environment(TelegramService.self) private var telegram
    @Environment(PlayerEngine.self) private var player

    @State private var localInput = NSearchInput()
    @State private var controller = MusicSearchController()
    @State private var selection = NTrackSelection()
    @State private var sourceID: String?
    @State private var showSearchSettings = false
    @State private var showNowPlaying = false
    @State private var retryToken = 0
    @State private var refreshRequested = false
    @State private var recents: [String] = NSearchView.loadRecents()
    @State private var scope: Scope = .all
    @State private var addTarget: AudioTrack?
    @State private var actionTarget: AudioTrack?
    @State private var hasFocusedInitially = false
    @FocusState private var focused: Bool

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", songs = "Songs", artists = "Artists", chats = "Chats", playlists = "Playlists"
        var id: String { rawValue }
    }

    private static let key = StorageKeys.recentSearches
    private var input: NSearchInput { sharedInput ?? localInput }
    private var query: String { input.text }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var effectiveLocal: LocalScope? { localScope }

    private var source: MusicSearchSource {
        telegram.searchSources.source(id: sourceID ?? telegram.searchSources.defaultSourceID)
    }
    private var visibleSongs: [AudioTrack] {
        if let local = effectiveLocal {
            return telegram.visible(trimmed.isEmpty ? AudioSearch.deduped(local.tracks) : AudioSearch.rank(local.tracks, query: trimmed, limit: Int.max))
        }
        return telegram.visible(controller.tracks)
    }
    private var requestID: String { "\(trimmed)|\(source.requestKey)|\(source.label)|\(retryToken)" }

    private var fullCollectionLoader: TrackCollectionLoader {
        let term = trimmed
        if let local = effectiveLocal {
            return {
                let tracks = try await local.loadAll?() ?? local.tracks
                return term.isEmpty ? AudioSearch.deduped(tracks) : AudioSearch.rank(tracks, query: term, limit: Int.max)
            }
        }
        let selectedSource = source
        return { try await telegram.allSearchMusic(source: selectedSource, query: term) }
    }

    var body: some View {
        NSearchNavigation(ownsStack: !embeddedInNavigation) {
            VStack(spacing: 12) {
                if !embeddedInNavigation {
                    Text("Search").font(.display(33)).tracking(-0.6).foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                searchBar
                if effectiveLocal != nil {
                    resultList.padding(.horizontal, -16)
                } else {
                    sourceTabs
                    if trimmed.isEmpty {
                        recentsList
                    } else {
                        if source.isTelegram { scopeChips }
                        resultList.padding(.horizontal, -16)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                // Tap anywhere off the results to put the keyboard away (the other half of
                // `scrollDismissesKeyboard`: a short result list leaves bare background to tap).
                ScreenBackground()
                    .contentShape(Rectangle())
                    .onTapGesture { endEditing() }
            )
            .toolbar(usesNativeSearch && embeddedInNavigation ? .visible : .hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(embeddedInNavigation)
            .modifier(NSearchTabChrome(enabled: usesNativeSearch && embeddedInNavigation, isEmbedded: embeddedInNavigation))
            .toolbar {
                if usesNativeSearch && embeddedInNavigation {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close search", systemImage: "xmark", action: closeSearch)
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("search.close")
                    }
                }
            }
            .onChange(of: input.focusRequest) { _, _ in focused = true }
            .onSubmit(of: .search) {
                if !trimmed.isEmpty { addRecent(trimmed) }
                endEditing()
            }
            .nMusicDestinations()
            .sheet(item: $addTarget) { track in NAddToPlaylistSheet(track: track) }
            .sheet(item: $actionTarget) { track in NTrackActionsSheet(track: track, showsSourceActions: false, fromSearch: true) }
            .sheet(isPresented: $showSearchSettings) { NSearchSettingsView() }
            .task(id: requestID) {
                selection.cancel()
                if effectiveLocal == nil { await runSearch() }
            }
            .onChange(of: selection.isSelecting) { _, selecting in if selecting { endEditing() } }
            .onChange(of: scope) { _, _ in selection.cancel() }
            .trackSelection(tracks: visibleSongs, selection: selection, loadAll: fullCollectionLoader)
            .modifier(NSearchOverlayPresentation(isTab: isTab, showNowPlaying: $showNowPlaying,
                onExpand: { endEditing(); showNowPlaying = true }))
        }
        .onDisappear { focused = false }
        .onAppear {
            if sourceID == nil { sourceID = telegram.searchSources.defaultSourceID }
            if !hasFocusedInitially {
                hasFocusedInitially = true
                if !isTab || embeddedInNavigation { focused = true }
                AnalyticsService.logOpenSearch()
            }
        }
    }

    /// Telegram-style horizontal filter bar (replaces the iOS segmented control).
    private var scopeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Scope.allCases) { s in
                    Button { withAnimation(.snappy(duration: 0.2)) { scope = s } } label: {
                        Text(s.rawValue).font(.subheadline.weight(.semibold))
                            .foregroundStyle(scope == s ? theme.accentText : theme.text)
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .nChipSurface(selected: scope == s, theme: theme)
                    }
                    .buttonStyle(NPressable(scale: 0.96))
                    .accessibilityAddTraits(scope == s ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func endEditing() {
        focused = false
    }

    private func closeSearch() {
        endEditing()
        if let onClose { onClose() } else { dismiss() }
    }

    // MARK: Search field + page close

    private var searchBar: some View {
        @Bindable var input = input
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: SearchChrome.iconSize, weight: .medium)).foregroundStyle(theme.text3)
                TextField("", text: $input.text, prompt: Text(effectiveLocal.map { "Find in \($0.title)" } ?? "Songs, artists, chats, playlists").foregroundStyle(theme.text3))
                    .font(.body).foregroundStyle(theme.text).focused($focused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    // Return commits the term and gets the keyboard out of the way of the results.
                    .onSubmit {
                        if !trimmed.isEmpty { addRecent(trimmed) }
                        endEditing()
                    }
                if !query.isEmpty {
                    Button { input.text = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.text3)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                        .accessibilityIdentifier("search.clear")
                }
            }
            .padding(.horizontal, 14).frame(minHeight: SearchChrome.height)
            .nGlass(SearchChrome.shape, theme: theme)

            if !isTab || (embeddedInNavigation && !usesNativeSearch) {
                closeButton
            }
        }
    }

    private var closeButton: some View {
        Button(action: closeSearch) {
            Image(systemName: "xmark")
                .font(.body)
                .foregroundStyle(theme.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close search")
        .accessibilityIdentifier("search.close")
    }

    // MARK: Recent searches

    @ViewBuilder private var recentsList: some View {
        if recents.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 30)).foregroundStyle(theme.text3)
                Text("Search your music").font(.system(size: 15)).foregroundStyle(theme.text2)
            }.frame(maxWidth: .infinity).padding(.top, 80)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent searches").font(.subheadline.weight(.semibold)).foregroundStyle(theme.text2)
                    Spacer()
                    Button("Clear") { withAnimation { recents = []; saveRecents() } }
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(theme.accentColor)
                }
                .padding(.top, 4)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(recents, id: \.self) { term in
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath").font(.system(size: 15)).foregroundStyle(theme.text3)
                                Text(term).font(.body).foregroundStyle(theme.text)
                                Spacer()
                                Button { withAnimation { removeRecent(term) } } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(theme.text3)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove “\(term)” from recent searches")
                            }
                            .padding(.vertical, 4).contentShape(Rectangle())
                            .onTapGesture { input.text = term }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { input.text = term }
                        }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                .modifier(NScrollDockViewport())
            }
        }
    }

    /// Acting on a result: remember the term and drop the keyboard, so returning from a pushed
    /// screen doesn't land back on a covered list.
    private func commit() {
        if !trimmed.isEmpty { addRecent(trimmed) }
        endEditing()
    }

    private func runSearch() async {
        let refresh = refreshRequested
        refreshRequested = false
        await controller.search(source: source, query: trimmed, refresh: refresh) { source, query, offset in
            try await telegram.searchMusic(source: source, query: query, offset: offset)
        }
    }

    private var resultList: some View {
        NSearchResultsView(songs: visibleSongs, query: trimmed, source: source, scope: scope,
                           localContext: effectiveLocal?.context, controller: controller,
                           onCommit: commit, onRetry: { refreshRequested = true; retryToken += 1 },
                           onLoadMore: { await controller.loadMore { source, query, offset in
                               try await telegram.searchMusic(source: source, query: query, offset: offset)
                           } },
                           onSearchTelegram: { sourceID = MusicSearchSource.telegram.id },
                           addTarget: $addTarget, actionTarget: $actionTarget)
    }

    private var sourceTabs: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(telegram.searchSources.sources) { item in
                        Button {
                            selection.cancel()
                            sourceID = item.id
                            scope = .all
                        } label: {
                            Text(item.label).font(.subheadline.weight(.semibold))
                                .foregroundStyle(source.id == item.id ? theme.accentText : theme.text)
                                .padding(.horizontal, 14).frame(minHeight: 44)
                                .nChipSurface(selected: source.id == item.id, theme: theme)
                        }
                        .buttonStyle(NPressable(scale: 0.96))
                        .accessibilityAddTraits(source.id == item.id ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 2)
            }
            Button { showSearchSettings = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Manage search sources")
        }
    }

    // MARK: Recent searches persistence

    private static func loadRecents() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    private func saveRecents() { UserDefaults.standard.set(recents, forKey: Self.key) }
    private func addRecent(_ q: String) {
        let term = q.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        recents = [term] + recents.filter { $0.lowercased() != term.lowercased() }
        recents = Array(recents.prefix(8)); saveRecents()
    }
    private func removeRecent(_ q: String) { recents.removeAll { $0 == q }; saveRecents() }
}
