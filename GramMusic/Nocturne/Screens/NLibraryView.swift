import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Library (screens §4) — a single unified list of everything the user keeps: playlists,
/// followed artists, and imported chats. Filter chips narrow it to one kind; a find field and
/// a sort toggle reshape it; the ＋ menu creates a playlist, adds a chat, or adds an artist.
struct NLibraryView: View {
    @Binding var pendingPlayerSource: NPlayerSourceRoute?
    let onSearch: () -> Void

    init(pendingPlayerSource: Binding<NPlayerSourceRoute?> = .constant(nil), onSearch: @escaping () -> Void = {}) {
        _pendingPlayerSource = pendingPlayerSource
        self.onSearch = onSearch
    }

    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    @Environment(PlayerEngine.self) private var player
    @Environment(ImportStore.self) private var importStore
    @Environment(\.modelContext) private var context
    @Query private var playlists: [Playlist]

    @State private var filter: Filter? = nil
    @State private var chatSubFilter: ChatSubFilter? = nil
    @State private var sort: SortMode = .recent
    @State private var showNewPlaylist = false
    @State private var showImportMore = false
    @State private var path = NavigationPath()
    @State private var draggedItem: String?
    @State private var showAddArtist = false
    @State private var pendingAddSongs: Playlist?
    @State private var addSongsTarget: Playlist?

    enum Filter: String, CaseIterable, Identifiable {
        case playlists = "Playlists", artists = "Artists", chats = "Chats"
        var id: String { rawValue }
    }
    enum ChatSubFilter: String, CaseIterable, Identifiable {
        case channels = "Channels"
        case profiles = "Profiles"
        case groups = "Groups"
        case personal = "Personal"
        case bots = "Bots"
        var id: String { rawValue }
    }
    enum SortMode: String, CaseIterable, Identifiable {
        case recent = "Recents", alpha = "Alphabetical"
        var id: String { rawValue }
        var symbol: String { self == .recent ? "clock" : "arrow.up.arrow.down" }
    }

    /// One row in the unified list.
    fileprivate enum Entry: Identifiable, Equatable {
        case playlist(Playlist), artist(String), chat(TelegramChat), profile(UserProfilePlaylist)
        var id: String {
            switch self {
            case .playlist(let p): p.pinKey
            case .artist(let n): "a:\(n.lowercased())"
            case .chat(let c): "c:\(c.id)"
            case .profile(let u): u.pinKey
            }
        }
        var sortName: String {
            switch self {
            case .playlist(let p): p.name
            case .artist(let n): n
            case .chat(let c): c.title
            case .profile(let u): u.title
            }
        }
        /// Stable key matching `TelegramService.pinnedKeys` (see there).
        var pinKey: String { id }
    }

    private var service: PlaylistService { PlaylistService(context: context) }
    private var sortedPlaylists: [Playlist] { playlists.sortedForLibrary }
    private var importedChats: [TelegramChat] { telegram.chats.filter { importStore.isChatImported($0.id) && ($0.audioCount ?? 0) > 0 } }
    private var importedProfiles: [UserProfilePlaylist] { telegram.userProfiles.filter { importStore.isProfileImported($0.userId) } }

    @State private var entries: [Entry] = []

    /// Cheap identity-only hash. `TelegramChat`'s synthesized `Hashable` includes `photoData` —
    /// the chat's minithumbnail — so combining the chats themselves fed every byte of every
    /// imported chat's photo through `Hasher`, on every body pass of this screen.
    private var dependencyHash: Int {
        var hasher = Hasher()
        hasher.combine(filter)
        hasher.combine(chatSubFilter)
        hasher.combine(sort)
        for playlist in playlists {
            hasher.combine(playlist.persistentModelID)
            hasher.combine(playlist.updatedAt)
            hasher.combine(playlist.name)
            hasher.combine(playlist.trackCount)
        }
        hasher.combine(telegram.followedArtists)
        for chat in importedChats {
            hasher.combine(chat.id)
            hasher.combine(chat.audioCount ?? 0)
            hasher.combine(chat.lastAudioDate)
        }
        for profile in importedProfiles { hasher.combine(profile.userId) }
        for key in telegram.lastOpened.keys.sorted() {
            hasher.combine(key)
            hasher.combine(telegram.lastOpened[key])
        }
        return hasher.finalize()
    }

    /// The composed, filtered, sorted entry list. "Recents" floats the entries you most recently
    /// opened to the top (across all three types), keyed by `telegram.lastOpened`; never-opened
    /// entries keep their natural per-type order (playlists library-sorted, artists newest-follow,
    /// chats by activity) below them.
    private func computeEntries() -> [Entry] {
        var all: [Entry] = []
        if filter == nil {
            all += sortedPlaylists.map(Entry.playlist)
            all += telegram.followedArtists.map(Entry.artist)
            all += importedChats.map(Entry.chat)
            all += importedProfiles.map(Entry.profile)
        } else if filter == .playlists {
            all += sortedPlaylists.map(Entry.playlist)
        } else if filter == .artists {
            all += telegram.followedArtists.map(Entry.artist)
        } else if filter == .chats {
            if let sf = chatSubFilter {
                switch sf {
                case .channels:
                    all += importedChats.filter { $0.kind == .channel }.map(Entry.chat)
                case .profiles:
                    all += importedProfiles.map(Entry.profile)
                case .groups:
                    all += importedChats.filter { $0.kind == .group }.map(Entry.chat)
                case .personal:
                    all += importedChats.filter { $0.kind == .privateChat || $0.kind == .savedMessages }.map(Entry.chat)
                case .bots:
                    all += importedChats.filter { $0.kind == .bot }.map(Entry.chat)
                }
            } else {
                all += importedChats.map(Entry.chat)
                all += importedProfiles.map(Entry.profile)
            }
        }
        switch sort {
        case .alpha:
            all.sort { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }
        case .recent:
            // Stable: opened entries by most-recent first; ties and never-opened keep insertion order.
            let opened = telegram.lastOpened
            all = all.enumerated().sorted { a, b in
                let aDate = a.element.activityDate(lastOpened: opened[a.element.pinKey])
                let bDate = b.element.activityDate(lastOpened: opened[b.element.pinKey])
                switch (aDate, bDate) {
                case let (x?, y?): return x != y ? x > y : a.offset < b.offset
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return a.offset < b.offset
                }
            }.map(\.element)
        }
        return all
    }


    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                header
                SearchBarButton(prompt: "Search music", action: onSearch)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("library.search")
                chips
                list
            }
            .background(ScreenBackground())
            .navigationBarHidden(true)
            .nMusicDestinations()
            .navigationDestination(for: NPlayerSourceRoute.self) { source in
                switch source {
                case .chat(let chat): NChatAudioView(chat: chat)
                case .profile(let profile): NProfilePlaylistDetailView(profile: profile)
                case .ownProfile: NPlaylistDetailView(playlist: service.profilePlaylist())
                }
            }
            .sheet(isPresented: $showNewPlaylist,
                   onDismiss: { addSongsTarget = pendingAddSongs; pendingAddSongs = nil }) {
                NNewPlaylistSheet { name, coverData in
                    let playlist = service.create(name: name, coverImageData: coverData)
                    telegram.setPinned(playlist.pinKey, true, atFront: true)
                    service.setPinned(playlist, true)
                    telegram.markOpened(playlist.pinKey)
                    pendingAddSongs = playlist
                }
            }
            .sheet(item: $addSongsTarget) { NAddSongsSheet(playlist: $0) }
            .sheet(isPresented: $showImportMore) {
                NImportChatsView(store: importStore) { showImportMore = false }
            }
            .sheet(isPresented: $showAddArtist) {
                let extra = playlists.flatMap { $0.tracks.map(\.performer) }
                NAddArtistSheet(suggestions: telegram.suggestedArtists(extraPerformers: extra))
            }
            .task {
                entries = computeEntries()
                _ = service.favorites()
                _ = service.profilePlaylist()   // always present, even with no profile music yet
                // Favorites / Profile Music / Save Message are pinned by default the first time each appears;
                // after that the user can unpin them and it sticks.
                let smartPins = sortedPlaylists.filter(\.isSmart).map(\.pinKey)
                let savedPins = importedChats.filter { $0.kind == .savedMessages && ($0.audioCount ?? 0) > 0 }.map { "c:\($0.id)" }
                telegram.seedDefaultPins(smartPins + savedPins)
            }
            .onChange(of: dependencyHash) { _, _ in
                telegram.seedDefaultPins(sortedPlaylists.filter(\.isSmart).map(\.pinKey))
                entries = computeEntries()
            }
            .onChange(of: pendingPlayerSource) { _, source in
                openPlayerSource(source)
            }
            .onAppear {
                AnalyticsService.logOpenLibrary()
                openPlayerSource(pendingPlayerSource)
            }
        }
    }

    private func openPlayerSource(_ source: NPlayerSourceRoute?) {
        guard let source else { return }
        // A player source link starts a fresh Library route, preserving the shared dock.
        path = NavigationPath()
        path.append(source)
        pendingPlayerSource = nil
    }

    // MARK: Header + ＋ menu

    private var header: some View {
        HStack {
            Text("Library").font(.display(33)).tracking(-0.6).foregroundStyle(theme.text)
            Spacer()
            Menu {
                Button { showNewPlaylist = true } label: { Label("Create playlist", systemImage: "plus.rectangle.on.folder") }
                Button { showImportMore = true } label: { Label("Add chat", systemImage: "bubble.left.and.bubble.right") }
                Button { showAddArtist = true } label: { Label("Add artist", systemImage: "person.crop.circle.badge.plus") }
            } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.accentColor).frame(width: 44, height: 44)
                    // Solid surface, not glass: Liquid Glass on this tiny control flashed a
                    // rectangular shadow while the menu opened/closed.
                    .background(Circle().fill(theme.elev))
                    .overlay(Circle().strokeBorder(theme.hairline, lineWidth: 0.5))
            }
            .accessibilityLabel("Add to Library")
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    // MARK: Filter chips + sort

    /// When a chip is chosen the others fall away and only it remains — so it keeps its identity
    /// (same `ForEach` element) and smoothly slides to the leading edge as the ✕ fades in.
    private var visibleFilters: [Filter] {
        if let f = filter { return [f] }
        return Filter.allCases
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if filter != nil {
                            Button {
                                withAnimation(.snappy(duration: 0.28)) {
                                    filter = nil
                                    chatSubFilter = nil
                                }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(theme.accentText).frame(width: 44, height: 44)
                                    .background(Circle().fill(theme.accent.fillGradient))
                            }
                            .buttonStyle(NPressable(scale: 0.94))
                            .accessibilityLabel("Clear library filter")
                            .transition(.scale.combined(with: .opacity))
                        }
                        ForEach(visibleFilters) { f in
                            chip(f.rawValue, selected: filter == f) {
                                withAnimation(.snappy(duration: 0.28)) {
                                    if filter == f {
                                        filter = nil
                                        chatSubFilter = nil
                                    } else {
                                        filter = f
                                        chatSubFilter = nil
                                    }
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                
                sortButton
                    .padding(.trailing, 16)
            }

            if filter == .chats {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ChatSubFilter.allCases) { sf in
                            chip(sf.rawValue, selected: chatSubFilter == sf) {
                                withAnimation(.snappy(duration: 0.28)) {
                                    chatSubFilter = (chatSubFilter == sf) ? nil : sf
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: filter)
        .animation(.snappy(duration: 0.28), value: chatSubFilter)
    }

    /// Single tap flips between Recents and Alphabetical (no menu).
    private var sortButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { sort = (sort == .recent) ? .alpha : .recent }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: sort.symbol)
                    .contentTransition(.symbolEffect(.replace))
                Text(sort.rawValue)
                    .contentTransition(.interpolate)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.text2)
        }
        .buttonStyle(NPressable(scale: 0.96))
        .frame(minHeight: 44)
        .accessibilityLabel("Sort library")
        .accessibilityValue(sort.rawValue)
        .sensoryFeedback(.selection, trigger: sort)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? theme.accentText : theme.text)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .nChipSurface(selected: selected, theme: theme)
        }
        .buttonStyle(NPressable(scale: 0.96))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: List

    private var list: some View {
        // ScrollView + LazyVStack (NOT `List`): only this animates a pinned row *sliding* up/down
        // when the order changes. Tap = open, swipe right = pin/unpin, swipe left = remove.
        // Pinned items float to the top in *every* view — the unfiltered list and each chip
        // filter (e.g. pinned playlists lead the Playlists filter).
        let pinRank = Dictionary(telegram.pinnedKeys.enumerated().map { ($1, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let pinned = entries.filter { pinRank[$0.pinKey] != nil }
            .sorted { (pinRank[$0.pinKey] ?? .max) < (pinRank[$1.pinKey] ?? .max) }
        let unpinned = entries.filter { pinRank[$0.pinKey] == nil }
        let ordered = pinned + unpinned

        return ScrollView {
            LazyVStack(spacing: 0) {
                if ordered.isEmpty {
                    emptyRow(emptyMessage)
                } else {
                    ForEach(ordered) { entry in
                        rowCell(entry, pinned: pinRank[entry.pinKey] != nil, pinnedItems: pinned)
                    }
                }
            }
            // One implicit animation: rows glide to their new spots when the order changes.
            .animation(.pinSpring, value: ordered.map(\.id))
            .nMiniPlayerClearance(player.current != nil, offline: telegram.isOfflineStable, base: 16)
        }
        .scrollDismissesKeyboard(.immediately)
        .modifier(NScrollDockViewport())
        // Light haptic whenever the pinned set/order changes.
        .sensoryFeedback(.impact(weight: .light), trigger: telegram.pinnedKeys)
    }

    /// Row content + pinned tint + separator. Swipe right = pin/unpin, swipe left = remove.
    /// Tap- to-open is a tap *gesture* (not a NavigationLink button) so a swipe never triggers it.
    @ViewBuilder private func rowCell(_ entry: Entry, pinned: Bool, pinnedItems: [Entry]) -> some View {
        let trailing = trailingSpec(entry)
        let rowView = SwipePinRow(pinned: pinned,
                    trailingIcon: trailing.icon, trailingTint: trailing.tint,
                    onToggle: { togglePin(entry) },
                    onTrailing: trailing.action,
                    onTap: { navigate(entry) }) {
            VStack(spacing: 0) {
                row(for: entry)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                Divider().overlay(theme.hairline).padding(.leading, 16)
            }
            .background(pinned ? theme.text.opacity(0.045) : Color.clear)
        }
        
        if pinned {
            rowView
                .onDrag {
                    draggedItem = entry.pinKey
                    return NSItemProvider(object: entry.pinKey as NSString)
                } preview: {
                    Color.clear
                }
                .onDrop(of: [.text], delegate: PinnedDropDelegate(item: entry, items: pinnedItems, draggedItem: $draggedItem, telegram: telegram))
        } else {
            rowView
        }
    }

    private func navigate(_ entry: Entry) {
        telegram.markOpened(entry.pinKey)
        switch entry {
        case .playlist(let p): path.append(p)
        case .artist(let n): path.append(Artist(name: n))
        case .chat(let c): path.append(c)
        case .profile(let u): path.append(u)
        }
    }

    /// Swipe-left action per row kind. Empty icon = no left action (smart playlists).
    ///
    /// A chat's action **hides** it rather than deleting anything — nothing is removed from
    /// Telegram and nothing is thrown away, it just stops occupying a Library row, and the import
    /// screen brings it back. It wore a red `minus.circle`, which reads as "remove/unsubscribe" and
    /// oversells what it does.
    private func trailingSpec(_ entry: Entry) -> (icon: String, tint: Color, action: () -> Void) {
        switch entry {
        case .playlist(let p):
            return p.isSmart ? ("", .clear, {}) : ("trash", .red, { service.delete(p) })
        case .artist(let n):
            return ("person.fill.xmark", .red, { telegram.toggleFollow(artist: n) })
        case .chat(let c):
            return ("eye.slash", .orange, { importStore.hideChat(c.id) })
        case .profile(let u):
            return ("eye.slash", .orange, { importStore.hideProfile(u.userId) })
        }
    }

    private func togglePin(_ entry: Entry) {
        switch entry {
        case .playlist(let p):
            let pin = !telegram.isPinned(p.pinKey)
            telegram.setPinned(p.pinKey, pin); service.setPinned(p, pin)
        case .artist(let n):
            let key = "a:\(n.lowercased())"; telegram.setPinned(key, !telegram.isPinned(key))
        case .chat(let c):
            let key = "c:\(c.id)"; telegram.setPinned(key, !telegram.isPinned(key))
        case .profile(let u):
            let key = u.pinKey; telegram.setPinned(key, !telegram.isPinned(key))
        }
    }

    @ViewBuilder private func row(for entry: Entry) -> some View {
        switch entry {
        case .playlist(let p): playlistRow(p)
        case .artist(let n): artistRow(n)
        case .chat(let c): chatRow(c)
        case .profile(let u): profileRow(u)
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .playlists: return "No playlists yet. Tap ＋ to create one."
        case .artists: return "No followed artists yet. Tap ＋ ▸ Add artist, or follow one from their page."
        case .chats:
            if let sf = chatSubFilter {
                switch sf {
                case .channels: return "No channel chats found."
                case .profiles: return "No user profile playlists found."
                case .groups: return "No group chats found."
                case .personal: return "No personal chats found."
                case .bots: return "No bot chats found."
                }
            }
            return "No imported chats. Tap ＋ ▸ Add chat."
        case nil: return "Your library is empty. Tap ＋ to add a playlist, chat, or artist."
        }
    }

    // MARK: Rows

    @ViewBuilder private func playlistRow(_ p: Playlist) -> some View {
        NListRow(seed: p.name, title: p.name,
                 subtitle: (p.isSmart ? "Smart playlist · " : "Playlist · ") + "\(p.trackCount) tracks",
                 playlist: p.isSmart ? nil : p,
                 smart: p.isSmart, smartSymbol: p.symbolName, showChevron: false,
                 pinned: telegram.isPinned(p.pinKey), size: 58)
    }

    @ViewBuilder private func artistRow(_ name: String) -> some View {
        NListRow(seed: name, title: name, subtitle: "Artist", kind: .artist,
                 showChevron: false, pinned: telegram.isPinned("a:\(name.lowercased())"), size: 58)
    }

    @ViewBuilder private func chatRow(_ chat: TelegramChat) -> some View {
        HStack(spacing: 12) {
            NChatAvatar(chat: chat, size: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.body.weight(.medium)).foregroundStyle(theme.text).lineLimit(1)
                Text(chat.audioMeta).font(.subheadline).foregroundStyle(theme.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            if telegram.isPinned("c:\(chat.id)") {
                Image(systemName: "pin.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func profileRow(_ profile: UserProfilePlaylist) -> some View {
        HStack(spacing: 12) {
            NProfileAvatar(profile: profile, size: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.title).font(.body.weight(.medium)).foregroundStyle(theme.text).lineLimit(1)
                Text("Profile · \(profile.trackCount) track\(profile.trackCount == 1 ? "" : "s")").font(.subheadline).foregroundStyle(theme.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            if telegram.isPinned(profile.pinKey) {
                Image(systemName: "pin.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
        }
        .padding(.vertical, 6)
    }

    private func emptyRow(_ s: String) -> some View {
        let icon: String = {
            switch filter {
            case .playlists: return "music.note.list"
            case .artists: return "music.mic"
            case .chats:
                if chatSubFilter == .profiles { return "person.crop.rectangle.stack" }
                return "bubble.left.and.bubble.right"
            case nil: return "books.vertical"
            }
        }()
        
        return VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(theme.text3)
            Text(s).font(.system(size: 15)).foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 80).padding(.horizontal, 24)
    }
}

/// Swipe a row to the right past a threshold to pin/unpin it. Horizontal-only and simultaneous,
/// so vertical scrolling and the row's tap-to-open are untouched. A gray pin glyph fades in from
/// the leading edge during the swipe; the row never changes height (no gaps).
private struct SwipePinRow<Content: View>: View {
    let pinned: Bool
    let trailingIcon: String        // "" = no left (remove) action
    let trailingTint: Color
    let onToggle: () -> Void
    let onTrailing: () -> Void
    let onTap: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var swipeX: CGFloat = 0
    private let threshold: CGFloat = 80
    private var hasTrailing: Bool { !trailingIcon.isEmpty }

    var body: some View {
        ZStack {
            // Small glyphs revealed at the edges (overlay-style, so they never change row height).
            HStack {
                Image(systemName: pinned ? "pin.slash.fill" : "pin.fill")
                    .foregroundStyle(Color(.systemGray))
                    .opacity(swipeX > 0 ? min(swipeX / threshold, 1) : 0)
                    .padding(.leading, 24)
                Spacer(minLength: 0)
                if hasTrailing {
                    Image(systemName: trailingIcon)
                        .foregroundStyle(trailingTint)
                        .opacity(swipeX < 0 ? min(-swipeX / threshold, 1) : 0)
                        .padding(.trailing, 24)
                }
            }
            .font(.system(size: 18, weight: .semibold))
            content()
                .offset(x: swipeX)
                .contentShape(Rectangle())
                // Tap opens the row. A tap is cancelled the moment a drag moves, so a swipe
                // never opens anything.
                .onTapGesture { onTap() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 22)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    var x = v.translation.width
                    if x < 0 && !hasTrailing { x = 0 }
                    swipeX = max(-140, min(140, x))
                }
                .onEnded { _ in
                    let pin = swipeX > threshold
                    let remove = swipeX < -threshold && hasTrailing
                    withAnimation(.snappy(duration: 0.25)) { swipeX = 0 }
                    if pin { onToggle() } else if remove { onTrailing() }
                }
        )
    }
}

private struct PinnedDropDelegate: DropDelegate {
    let item: NLibraryView.Entry
    let items: [NLibraryView.Entry]
    @Binding var draggedItem: String?
    let telegram: TelegramService

    func dropEntered(info: DropInfo) {
        guard let draggedItem,
              draggedItem != item.pinKey,
              let from = items.firstIndex(where: { $0.pinKey == draggedItem }),
              let to = items.firstIndex(where: { $0.pinKey == item.pinKey }) else { return }

        if from != to {
            withAnimation(.pinSpring) {
                let keys = items.map(\.pinKey)
                telegram.reorderPinned(visibleKeys: keys, fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}

private extension NLibraryView.Entry {
    func activityDate(lastOpened: Date?) -> Date? {
        [lastOpened, fallbackDate].compactMap { $0 }.max()
    }

    var fallbackDate: Date? {
        switch self {
        case .playlist(let p): return p.updatedAt ?? p.createdAt
        case .chat(let c): return c.lastAudioDate
        case .profile(let u): return u.tracks.compactMap(\.date).max().map { Date(timeIntervalSince1970: Double($0)) }
        case .artist: return nil
        }
    }
}
