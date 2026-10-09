import Foundation

/// Fills in the tracks a recipe needs but the snapshot doesn't have yet.
///
/// `LibrarySnapshot.live` reads only memory caches, so a chat the user has never opened
/// contributes nothing and an artist they don't follow doesn't exist at all. That made the
/// assistant blind to most of a real library. Hydration closes the gap by fetching *only what the
/// recipe actually named* — never the whole library — right before selection.
///
/// It is a separate stage on purpose: `RecipeSelector` stays pure and synchronous (and therefore
/// testable from a literal), while every network call lives here. The decision of *what* to fetch
/// is itself a pure function (`plan`), so the expensive part is testable without a backend.
@MainActor
struct SnapshotHydrator {

    let telegram: TelegramService

    /// What a recipe needs that the snapshot can't answer yet.
    nonisolated struct Plan: Equatable {
        /// Known chats whose audio isn't cached.
        var chatsToFetch: [LibrarySnapshot.Chat] = []
        /// Artist names to run through Telegram search — either not followed at all, or followed
        /// but with no cached tracks.
        var artistsToSearch: [String] = []

        var isEmpty: Bool { chatsToFetch.isEmpty && artistsToSearch.isEmpty }
    }

    /// Decide what must be fetched. Pure — no I/O, no service calls, and deliberately
    /// `nonisolated`: planning touches nothing on the main actor, so it stays callable (and
    /// testable) from anywhere. Only `hydrate` needs the actor, because only it touches
    /// `TelegramService`.
    nonisolated static func plan(for recipe: PlaylistRecipe, given snapshot: LibrarySnapshot) -> Plan {
        var plan = Plan()

        for spoken in recipe.chats {
            guard let title = TextMatch.best(spoken, in: snapshot.chats.map(\.title)),
                  let chat = snapshot.chats.first(where: { $0.title == title }) else { continue }
            if (snapshot.tracksByChat[chat.id] ?? []).isEmpty {
                plan.chatsToFetch.append(chat)
            }
        }

        for spoken in recipe.artists {
            if let known = TextMatch.best(spoken, in: snapshot.artists),
               !(snapshot.tracksByArtist[known] ?? []).isEmpty {
                continue                                  // already have tracks for this artist
            }
            // Either an unfollowed artist, or a followed one with an empty cache. Both are
            // answerable by search — which is what makes the assistant able to reach any
            // performer in the user's Telegram, not just the ones they've already followed.
            plan.artistsToSearch.append(spoken)
        }

        return plan
    }

    /// Execute a plan, returning an enriched snapshot. Failures are swallowed per-item: one chat
    /// that won't load must not cost the user the rest of the playlist, and `RecipeSelector`
    /// already reports whatever ends up unmatched.
    func hydrate(_ recipe: PlaylistRecipe, into snapshot: LibrarySnapshot) async -> LibrarySnapshot {
        let plan = Self.plan(for: recipe, given: snapshot)
        guard !plan.isEmpty else { return snapshot }

        // Offline, the caches are all there is. Fetching would only stall the UI to fail.
        guard !telegram.isOffline else { return snapshot }

        var hydrated = snapshot

        for chat in plan.chatsToFetch {
            guard let tracks = try? await telegram.audioMessages(in: chat.id), !tracks.isEmpty else { continue }
            hydrated.tracksByChat[chat.id] = tracks
            telegram.cacheChatAudio(tracks, chatId: chat.id)
        }

        for spoken in plan.artistsToSearch {
            guard let found = try? await telegram.searchAudio(spoken), !found.isEmpty else { continue }

            // Search matches titles as well as performers, so keep only tracks whose *performer*
            // is the artist asked for — otherwise "Radiohead" pulls in every song with the word
            // in its title, and the playlist stops being what was asked for.
            let wanted = found.filter { TextMatch.score(spoken, against: $0.performer) >= TextMatch.confidentThreshold }
            let tracks = wanted.isEmpty ? found : wanted

            // Register under the canonical spelling the library already uses when there is one,
            // so the selector's own matching finds it.
            let key = TextMatch.best(spoken, in: hydrated.artists)
                ?? tracks.first(where: { !$0.performer.isEmpty })?.performer
                ?? spoken
            hydrated.tracksByArtist[key] = tracks
            if !hydrated.artists.contains(key) { hydrated.artists.append(key) }
            telegram.cacheArtistTracks(tracks, name: key)
        }

        return hydrated
    }
}
