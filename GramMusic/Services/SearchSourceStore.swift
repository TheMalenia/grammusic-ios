import Foundation
import Observation

/// Account-owned search preferences, shared by Home search and Settings.
@MainActor @Observable
final class SearchSourceStore {
    private(set) var generation = 0
    private(set) var bots: [MusicSearchBot]
    private(set) var defaultSourceID: String
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: StorageKeys.searchBots)
            .flatMap { try? JSONDecoder().decode([MusicSearchBot].self, from: $0) } ?? []
        var seen = Set<Int64>()
        let restoredBots = stored.filter { $0.id > 0 && seen.insert($0.id).inserted }
        let savedDefault = defaults.string(forKey: StorageKeys.defaultSearchSource) ?? MusicSearchSource.telegram.id
        bots = restoredBots
        defaultSourceID = restoredBots.contains { MusicSearchSource.bot($0).id == savedDefault }
            ? savedDefault : MusicSearchSource.telegram.id
    }

    var sources: [MusicSearchSource] { [.telegram] + bots.map(MusicSearchSource.bot) }
    var defaultSource: MusicSearchSource { source(id: defaultSourceID) }
    func source(id: String) -> MusicSearchSource { sources.first { $0.id == id } ?? .telegram }

    func add(_ bot: MusicSearchBot) {
        guard bot.id > 0 else { return }
        if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index] = bot }
        else { bots.append(bot) }
        persist()
    }

    func update(_ bot: MusicSearchBot, displayName: String?, queryPrefix: String?) {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[index] = MusicSearchBot(id: bot.id, username: bot.username, displayName: displayName, queryPrefix: queryPrefix)
        persist()
    }

    func remove(_ bot: MusicSearchBot) {
        bots.removeAll { $0.id == bot.id }
        if defaultSourceID == MusicSearchSource.bot(bot).id { defaultSourceID = MusicSearchSource.telegram.id }
        persist()
    }

    func setDefault(_ source: MusicSearchSource) {
        defaultSourceID = self.source(id: source.id).id
        persist()
    }

    func clear() {
        generation += 1
        bots = []
        defaultSourceID = MusicSearchSource.telegram.id
        defaults.removeObject(forKey: StorageKeys.searchBots)
        defaults.removeObject(forKey: StorageKeys.defaultSearchSource)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(bots) { defaults.set(data, forKey: StorageKeys.searchBots) }
        defaults.set(defaultSourceID, forKey: StorageKeys.defaultSearchSource)
    }
}
