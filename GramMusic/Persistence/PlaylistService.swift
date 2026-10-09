import Foundation
import SwiftData

/// CRUD + ordering operations over playlists, on top of a SwiftData `ModelContext`.
@MainActor
struct PlaylistService {
    let context: ModelContext

    @discardableResult
    func create(name: String, coverImageData: Data? = nil) -> Playlist {
        AnalyticsService.logCreatePlaylist()
        let playlist = Playlist(name: name.isEmpty ? "New Playlist" : name,
                                coverImageData: coverImageData)
        context.insert(playlist)
        save()
        return playlist
    }

    func setPinned(_ playlist: Playlist, _ pinned: Bool) {
        playlist.isPinned = pinned
        save()
    }

    /// Delete every playlist and track reference — used on log out, so no account data remains
    /// on-device. Smart playlists (Favorites/Downloaded) are recreated lazily on next use.
    func deleteAll() {
        for playlist in (try? context.fetch(FetchDescriptor<Playlist>())) ?? [] {
            context.delete(playlist)
        }
        for ref in (try? context.fetch(FetchDescriptor<TrackRef>())) ?? [] {
            context.delete(ref)
        }
        save()
    }

    /// Seed and ensure the default library playlists (Favorites, Downloaded, Your Profile) exist
    /// in SwiftData during the initial loading setup.
    func ensureSystemLibraryInitialized() {
        _ = favorites()
        _ = downloads()
        _ = profilePlaylist()
        if UserDefaults.standard.bool(forKey: StorageKeys.saveSearchResults) { _ = searchPlaylist() }
    }

    /// Look up a smart playlist by its flag.
    ///
    /// Deliberately *not* a `#Predicate` fetch: a predicate over a `@Model` class expands to a
    /// `ReferenceWritableKeyPath`, which can never be `Sendable` — an error under the Swift 6
    /// language mode. The playlist table is a handful of rows (the three smart playlists plus the
    /// user's own), so filtering them in memory costs nothing measurable.
    private func firstPlaylist(where matches: (Playlist) -> Bool) -> Playlist? {
        ((try? context.fetch(FetchDescriptor<Playlist>())) ?? []).first(where: matches)
    }

    // MARK: - Favorites (like)

    /// The Favorites playlist if it already exists (no side effects).
    func existingFavorites() -> Playlist? {
        firstPlaylist { $0.isFavorites }
    }

    /// Favorites playlist, creating (pinned) it on first use.
    @discardableResult
    func favorites() -> Playlist {
        if let existing = existingFavorites() { return existing }
        let playlist = Playlist(name: "Favorites")
        playlist.isFavorites = true
        playlist.isPinned = true
        context.insert(playlist)
        save()
        return playlist
    }

    func isFavorite(_ track: AudioTrack) -> Bool {
        existingFavorites()?.contains(track) ?? false
    }

    /// Toggle a track's favorite membership. Returns the new state.
    @discardableResult
    func toggleFavorite(_ track: AudioTrack) -> Bool {
        let fav = favorites()
        if let ref = fav.tracks.first(where: { $0.remoteUniqueId == track.remoteUniqueId }) {
            remove(ref, from: fav)
            return false
        } else {
            add(track, to: fav)
            return true
        }
    }

    // MARK: - Downloaded (offline library)

    func existingDownloads() -> Playlist? {
        firstPlaylist { $0.isDownloads }
    }

    @discardableResult
    func downloads() -> Playlist {
        if let existing = existingDownloads() { return existing }
        let playlist = Playlist(name: "Downloaded")
        playlist.isDownloads = true
        playlist.isPinned = true
        context.insert(playlist)
        save()
        return playlist
    }

    /// Record a track as downloaded so it appears in the Downloaded library.
    func recordDownload(_ track: AudioTrack) {
        add(track, to: downloads())
    }

    /// Drop a track from the Downloaded library (its file is deleted separately by the backend).
    func removeDownload(_ track: AudioTrack) {
        guard let dl = existingDownloads(),
              let ref = dl.tracks.first(where: { $0.remoteUniqueId == track.remoteUniqueId }) else { return }
        remove(ref, from: dl)
    }

    /// Any stored reference to this track, whichever playlist holds it. Used to recover enough of
    /// a track (its remote file id) to delete its file when the audio cache evicts it.
    func anyTrackRef(remoteUniqueId: String) -> TrackRef? {
        ((try? context.fetch(FetchDescriptor<TrackRef>())) ?? [])
            .first { $0.remoteUniqueId == remoteUniqueId }
    }

    /// Every track the user has stored in any playlist — Downloaded, Favorites, Profile Music and
    /// their own lists — as one de-duplicated array. Feeds the **offline half** of search, which is
    /// the only half there is when Telegram is unreachable.
    func allStoredTracks() -> [AudioTrack] {
        let refs = (try? context.fetch(FetchDescriptor<TrackRef>())) ?? []
        var seen = Set<String>()
        return refs.compactMap { ref in
            guard seen.insert(ref.remoteUniqueId).inserted else { return nil }
            return ref.audioTrack
        }
    }

    // MARK: - Search listening history (opt-in)

    /// Saving is explicitly gated here; displaying search results never calls this method.
    /// Use an identity flag rather than a name: a user's own "Search" playlist is unrelated,
    /// and renaming this playlist must not split future results into a second collection.
    func recordSearchListen(_ track: AudioTrack, enabled: Bool) {
        guard enabled else { return }
        insert([track], into: searchPlaylist())
    }

    @discardableResult
    func searchPlaylist() -> Playlist {
        if let existing = firstPlaylist(where: { $0.isSearch }) { return existing }
        let playlist = Playlist(name: "Search")
        playlist.isSearch = true
        playlist.isPinned = true
        context.insert(playlist)
        save()
        return playlist
    }

    // MARK: - Profile Music (mirror of the user's Telegram profile audio)

    func existingProfile() -> Playlist? {
        firstPlaylist { $0.isProfile }
    }

    @discardableResult
    func profilePlaylist() -> Playlist {
        if let existing = existingProfile() {
            if existing.name != "Your Profile" {
                existing.name = "Your Profile"
                save()
            }
            return existing
        }
        let playlist = Playlist(name: "Your Profile")
        playlist.isProfile = true
        playlist.isPinned = true
        context.insert(playlist)
        save()
        return playlist
    }

    /// Mirror the server's ordered profile-audio list into the Profile Music playlist. The server
    /// is the source of truth. This **reconciles in place** rather than deleting and re-inserting
    /// every ref: it deletes only the refs that are gone, reuses the ones that remain (just fixing
    /// their order), and inserts the new ones. Crucially this keeps the surviving `TrackRef`
    /// objects alive — a full delete+reinsert would yank objects out from under a `ForEach`/`onMove`
    /// that's bound to them on the open detail screen (an "accessing a deleted object" crash). The
    /// playlist is always present (created on demand) — shown even when empty, like a pre-built
    /// smart playlist.
    func replaceProfileAudio(with tracks: [AudioTrack]) {
        let playlist = profilePlaylist()
        let desired = Set(tracks.map(\.remoteUniqueId))
        if playlist.orderedTracks.map(\.remoteUniqueId) != tracks.map(\.remoteUniqueId) {
            playlist.updatedAt = .now
        }

        // Drop refs no longer on the server (iterate a snapshot; the live relationship mutates).
        // One pass, one relationship rewrite. This used to sort the whole relationship and then
        // run a full `removeAll` scan *per removed ref* — O(k·n) mutations of a SwiftData
        // relationship, on a sync that fires on every connection recovery.
        let doomed = playlist.tracks.filter { !desired.contains($0.remoteUniqueId) }
        if !doomed.isEmpty {
            let doomedIDs = Set(doomed.map { ObjectIdentifier($0) })
            playlist.tracks.removeAll { doomedIDs.contains(ObjectIdentifier($0)) }
            for ref in doomed { context.delete(ref) }
        }

        // Reuse survivors, insert newcomers, and (re)assign order to match the server list.
        var byId = Dictionary(playlist.tracks.map { ($0.remoteUniqueId, $0) }, uniquingKeysWith: { a, _ in a })
        for (index, track) in tracks.enumerated() {
            if let ref = byId[track.remoteUniqueId] {
                ref.order = index
            } else {
                let ref = TrackRef(track: track, order: index)
                ref.playlist = playlist
                playlist.tracks.append(ref)
                context.insert(ref)
                byId[track.remoteUniqueId] = ref
            }
        }
        save()
    }

    func rename(_ playlist: Playlist, to name: String) {
        guard !name.isEmpty else { return }
        playlist.name = name
        save()
    }

    func setCoverImage(_ playlist: Playlist, data: Data?) {
        playlist.coverImageData = data
        save()
    }

    func delete(_ playlist: Playlist) {
        context.delete(playlist)
        save()
    }

    /// Add a track to a *local* playlist.
    ///
    /// Profile Music is rejected on purpose: it mirrors the user's Telegram profile, so a local
    /// insert ticks the UI without the song ever reaching Telegram, and the next `syncProfileAudio()`
    /// reconciles it away again. That is exactly the bug the "Add to playlist" sheet shipped with.
    /// Go through `TelegramService.addToProfile(_:)`; `replaceProfileAudio(with:)` is how the
    /// mirror itself gets written.
    func add(_ track: AudioTrack, to playlist: Playlist) {
        guard !playlist.isProfile, !playlist.isSearch else {
            log.error("Refusing a manual add to an automatic playlist")
            return
        }
        guard !playlist.tracks.contains(where: { $0.remoteUniqueId == track.remoteUniqueId }) else { return }
        AnalyticsService.logAddToPlaylist()
        // **Newest first.** A track you just added is the one you want to see, and appending it
        // put it at the bottom of a long playlist where you had to scroll to find it. Everything
        // already there shifts down by one and the new ref takes slot 0.
        for existing in playlist.tracks { existing.order += 1 }
        let ref = TrackRef(track: track, order: 0)
        ref.playlist = playlist
        playlist.tracks.append(ref)   // membership; `orderedTracks` sorts by `order`
        playlist.updatedAt = .now
        context.insert(ref)
        save()
    }

    /// Preserve the selection's order at the front and save once for the entire batch.
    func add(_ tracks: [AudioTrack], to playlist: Playlist) {
        guard !playlist.isSmart else { return }
        insert(tracks, into: playlist)
    }

    private func insert(_ tracks: [AudioTrack], into playlist: Playlist) {
        var seen = Set(playlist.tracks.map(\.remoteUniqueId))
        let fresh = tracks.filter { seen.insert($0.remoteUniqueId).inserted }
        guard !fresh.isEmpty else { return }
        for existing in playlist.tracks { existing.order += fresh.count }
        for (order, track) in fresh.enumerated() {
            let ref = TrackRef(track: track, order: order)
            ref.playlist = playlist
            playlist.tracks.append(ref)
            context.insert(ref)
        }
        playlist.updatedAt = .now
        AnalyticsService.logAddToPlaylist()
        save()
    }

    func remove(_ ref: TrackRef, from playlist: Playlist) {
        playlist.tracks.removeAll { $0 === ref }
        context.delete(ref)
        reindex(playlist)
        playlist.updatedAt = .now
        save()
    }

    func removeTracks(_ tracks: [AudioTrack], from playlist: Playlist) {
        let ids = Set(tracks.map(\.remoteUniqueId))
        let removed = playlist.tracks.filter { ids.contains($0.remoteUniqueId) }
        guard !removed.isEmpty else { return }
        playlist.tracks.removeAll { ids.contains($0.remoteUniqueId) }
        for ref in removed { context.delete(ref) }
        reindex(playlist)
        playlist.updatedAt = .now
        save()
    }

    func clearSearchPlaylist(_ playlist: Playlist) {
        guard playlist.isSearch else { return }
        removeTracks(playlist.orderedTracks.map(\.audioTrack), from: playlist)
    }

    /// Remove any track references matching the unavailable IDs from a playlist.
    /// Returns the number of removed tracks.
    @discardableResult
    func removeUnavailableTracks(from playlist: Playlist, unavailableIds: Set<String>) -> Int {
        guard !unavailableIds.isEmpty else { return 0 }
        let toRemove = playlist.tracks.filter { unavailableIds.contains($0.remoteUniqueId) }
        guard !toRemove.isEmpty else { return 0 }
        for ref in toRemove {
            playlist.tracks.removeAll { $0 === ref }
            context.delete(ref)
        }
        reindex(playlist)
        playlist.updatedAt = .now
        save()
        return toRemove.count
    }

    /// Move tracks within a playlist (drag-to-reorder from a SwiftUI List).
    func move(in playlist: Playlist, from source: IndexSet, to destination: Int) {
        var ordered = playlist.orderedTracks
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, ref) in ordered.enumerated() { ref.order = index }
        playlist.updatedAt = .now
        save()
    }

    private func reindex(_ playlist: Playlist) {
        for (index, ref) in playlist.orderedTracks.enumerated() { ref.order = index }
    }

    /// Persist pending changes.
    ///
    /// A failure here loses a user edit (a new playlist, a reorder, a favourite), so it must not
    /// vanish: `assertionFailure` alone compiled out in release, making every release-build save
    /// failure completely silent. Now always logged, and still trapped in debug so it surfaces
    /// during development.
    private func save() {
        do {
            try context.save()
        } catch {
            log.error("SwiftData save failed: \(error.localizedDescription, privacy: .public)")
            assertionFailure("SwiftData save failed: \(error)")
        }
    }
}
