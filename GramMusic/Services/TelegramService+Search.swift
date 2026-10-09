import Foundation

extension TelegramService {
    /// Connect only after Telegram verifies that the username supports inline queries.
    func connectSearchBot(_ input: String, displayName: String? = nil) async throws {
        let connection = try MusicSearchBot.parseConnection(input)
        let generation = searchSources.generation
        let botID = try await backend.resolveBot(username: connection.username)
        try Task.checkCancellation()
        guard authState == .ready, generation == searchSources.generation else { throw TelegramError.notReady }
        searchSources.add(MusicSearchBot(id: botID, username: connection.username, displayName: displayName, queryPrefix: connection.queryPrefix))
    }

    func searchMusic(source: MusicSearchSource, query: String, offset: String = "", allowLocalFallback: Bool = true) async throws -> MusicSearchPage {
        switch source {
        case .telegram:
            let local = offset.isEmpty ? await localMatches(for: query, limit: Int.max) : []
            guard !isOffline else {
                guard offset.isEmpty else { throw TelegramError.backend("Connection lost while loading all songs. Please try again.") }
                return MusicSearchPage(tracks: local)
            }
            let page: MusicSearchPage
            do { page = try await backend.searchAudioPage(query: query, offset: offset) }
            catch {
                if allowLocalFallback && offset.isEmpty && !local.isEmpty { return MusicSearchPage(tracks: local) }
                throw error
            }
            for track in page.tracks { markTrackAvailable(track) }
            return MusicSearchPage(tracks: visible(AudioSearch.rank(page.tracks + local, query: query, limit: Int.max)),
                                   nextOffset: page.nextOffset)
        case .bot(let bot):
            guard !isOffline else { throw TelegramError.backend("Bot search needs an internet connection. Try the Telegram tab for saved music.") }
            return try await InlineMusicSearch.load(bot: bot, query: query, offset: offset,
                context: {
                    try await self.inlineSearchContext.resolve {
                        try await self.backend.inlineMusicSearchChatId()
                    }
                },
                fetch: { botID, chatID, query, offset in
                    try await self.backend.getInlineQueryResults(botUserId: botID, chatId: chatID, query: query, offset: offset)
                })
        }
    }
    func allSearchMusic(source: MusicSearchSource, query: String) async throws -> [AudioTrack] {
        let tracks = try await TrackCollection.load { offset in
            try await self.searchMusic(source: source, query: query, offset: offset, allowLocalFallback: false)
        }
        return source.isTelegram ? AudioSearch.rank(tracks, query: query, limit: Int.max) : visible(tracks)
    }

    func allOwnProfileAudio() async throws -> [AudioTrack] {
        let tracks = try await TrackCollection.load { offset in
            try await self.backend.profileAudioPage(offset: Int(offset) ?? 0)
        }
        return visible(tracks)
    }

    func allProfileAudio(userId: Int64) async throws -> [AudioTrack] {
        let tracks = try await TrackCollection.load { offset in
            try await self.backend.userProfileAudioPage(userId: userId, offset: Int(offset) ?? 0)
        }
        return visible(tracks)
    }

    func removeSelectionFromProfile(_ tracks: [AudioTrack]) async throws {
        guard !isOffline else { throw TelegramError.backend("Connect to the internet to update your profile.") }
        do {
            for track in tracks {
                try Task.checkCancellation()
                try await backend.removeProfileAudio(track)
            }
        } catch {
            await syncProfileAudio()
            throw error
        }
        await syncProfileAudio()
    }

    func addSelectionToProfile(_ tracks: [AudioTrack]) async throws {
        guard !isOffline else { throw TelegramError.backend("Connect to the internet to update your profile.") }
        do {
            for track in tracks where !isProfileAudio(track) {
                try Task.checkCancellation()
                try await backend.addProfileAudio(track)
            }
        } catch {
            await syncProfileAudio()
            throw error
        }
        await syncProfileAudio()
    }
}
