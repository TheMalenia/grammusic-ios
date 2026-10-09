import Foundation

/// The one matching/ranking engine behind **every** search surface (the global overlay, find-in-
/// playlist/chat/artist, the add-songs sheet, the add-artist sheet).
///
/// Three jobs, all pure and therefore unit-tested (`AudioSearchTests`):
///
/// 1. **Folding.** Matching is case-, diacritic- and punctuation-insensitive, and unifies the
///    Arabic/Persian letter variants Telegram audio is full of (`ي`/`ی`, `ك`/`ک`, Arabic-Indic
///    digits, ZWNJ). Without that, "هندونه" typed with a Persian keyboard missed a title tagged
///    with the Arabic letters, and "Beyonce" missed "Beyoncé".
/// 2. **De-duplication.** The same song usually exists in several chats, so Telegram's message
///    search returns it several times — same audio file, different `chatId:messageId`. The stable
///    identity of *audio* is `remoteUniqueId`, so results collapse on that and keep the richest
///    copy (one that still has a source message, artwork, a real title).
/// 3. **Ranking.** Telegram returns matches newest-message-first, which buries the song whose
///    title *is* the query under whatever was posted most recently. Scoring puts exact and
///    prefix title matches on top, and every query token has to match somewhere (so "daft lucky"
///    finds "Get Lucky" by Daft Punk, and doesn't drag in everything containing "daft").
enum AudioSearch {

    // MARK: - Folding

    /// Normalised form used for all comparisons. Lowercased, diacritic-stripped, Arabic/Persian
    /// variants unified, and every run of non-alphanumeric characters collapsed to one space.
    static func fold(_ string: String) -> String {
        let unified = String(string.map(unify))
        let folded = unified.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                     locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        out.reserveCapacity(folded.count)
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator, !out.isEmpty { out.append(" ") }
                pendingSeparator = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        return out
    }

    /// Per-character unification of the variants that mean the same letter to a reader but are
    /// different code points — the Arabic vs. Persian forms, and the Arabic-Indic digits.
    private static func unify(_ character: Character) -> Character {
        switch character {
        case "ي", "ى", "ئ": return "ی"
        case "ك": return "ک"
        case "أ", "إ", "آ", "ٱ": return "ا"
        case "ة": return "ه"
        case "ؤ": return "و"
        case "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}": return " "   // ZWNJ / ZWJ / bidi marks
        case "٠", "۰": return "0"
        case "١", "۱": return "1"
        case "٢", "۲": return "2"
        case "٣", "۳": return "3"
        case "٤", "۴": return "4"
        case "٥", "۵": return "5"
        case "٦", "۶": return "6"
        case "٧", "۷": return "7"
        case "٨", "۸": return "8"
        case "٩", "۹": return "9"
        default: return character
        }
    }

    /// The folded, non-empty words of a query. Empty when the query has nothing to match on.
    static func tokens(_ query: String) -> [String] {
        fold(query).split(separator: " ").map(String.init)
    }

    // MARK: - Matching

    /// Score one folded field against one token, or `nil` when the token isn't in it.
    /// Exact > starts-with > word-starts-with > contains, so a title match ranks by how much of
    /// the field the user actually typed.
    private static func fieldScore(_ field: String, token: String) -> Int? {
        guard !field.isEmpty else { return nil }
        if field == token { return 100 }
        if field.hasPrefix(token) { return 60 }
        guard field.contains(token) else { return nil }
        if field.contains(" " + token) { return 40 }
        return 20
    }

    /// A track's folded, weighted fields. Title carries the most weight, then performer, then the
    /// file name (which is the fallback display title for untagged Telegram audio).
    private struct Fields {
        let title: String, performer: String, fileName: String

        init(_ track: AudioTrack) {
            title = AudioSearch.fold(track.title.isEmpty ? (track.fileName ?? "") : track.title)
            performer = AudioSearch.fold(track.performer)
            fileName = AudioSearch.fold(track.fileName ?? "")
        }

        /// Best score for a token across the fields, or `nil` when it matches none of them.
        func score(token: String) -> Int? {
            let candidates = [
                AudioSearch.fieldScore(title, token: token).map { $0 * 3 },
                AudioSearch.fieldScore(performer, token: token).map { $0 * 2 },
                AudioSearch.fieldScore(fileName, token: token)
            ].compactMap { $0 }
            return candidates.max()
        }
    }

    /// The relevance of a track to `tokens`, or `nil` when **any** token matches nothing (AND
    /// semantics — every word the user typed has to be somewhere in the track).
    static func score(_ track: AudioTrack, tokens: [String], foldedQuery: String) -> Int? {
        guard !tokens.isEmpty else { return nil }
        let fields = Fields(track)
        var total = 0
        for token in tokens {
            guard let score = fields.score(token: token) else { return nil }
            total += score
        }
        // Whole-query bonuses: the song the user is literally naming wins outright.
        if fields.title == foldedQuery { total += 1000 }
        else if fields.title.hasPrefix(foldedQuery) { total += 400 }
        if fields.performer == foldedQuery { total += 300 }
        else if fields.performer.hasPrefix(foldedQuery) { total += 120 }
        return total
    }

    /// Does `text` match every token of `query`? The string-only form, for chat/playlist/artist
    /// names, so they fold and tokenise exactly like track fields do.
    static func matches(_ text: String, query: String) -> Bool {
        let tokens = tokens(query)
        guard !tokens.isEmpty else { return true }
        let folded = fold(text)
        return tokens.allSatisfy { folded.contains($0) }
    }

    // MARK: - De-duplication

    /// The identity of the *audio*, not of the message carrying it. Falls back to the message key
    /// for the (mock/edge) case of a track with no remote id, so distinct tracks never collapse.
    static func identity(_ track: AudioTrack) -> String {
        track.remoteUniqueId.isEmpty ? track.id : track.remoteUniqueId
    }

    /// How complete a record is, used to pick which copy of a duplicate survives: one that still
    /// points at a source message (needed to play, add-to-profile and report) beats one that
    /// doesn't, then artwork, a real title, a performer, and a live session file id.
    private static func richness(_ track: AudioTrack) -> Int {
        var score = 0
        if track.messageId != 0 && track.chatId != 0 { score += 8 }
        if track.artworkData != nil { score += 4 }
        if !track.title.isEmpty { score += 2 }
        if !track.performer.isEmpty { score += 1 }
        if track.fileId > 0 { score += 1 }
        if track.mimeType != nil { score += 1 }
        return score
    }

    /// Order-preserving de-duplication by audio identity, keeping the richest copy of each.
    static func deduped(_ tracks: [AudioTrack]) -> [AudioTrack] {
        var order: [String] = []
        var best: [String: AudioTrack] = [:]
        for track in tracks {
            let key = identity(track)
            if let existing = best[key] {
                if richness(track) > richness(existing) { best[key] = track }
            } else {
                best[key] = track
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }

    // MARK: - Ranking

    /// De-duplicate, drop non-matches, and sort by relevance (then newest message, then title) —
    /// the single entry point every search surface uses.
    static func rank(_ tracks: [AudioTrack], query: String, limit: Int = 100) -> [AudioTrack] {
        let tokens = tokens(query)
        guard !tokens.isEmpty else { return Array(deduped(tracks).prefix(limit)) }
        let foldedQuery = fold(query)
        let scored = deduped(tracks).compactMap { track -> (AudioTrack, Int)? in
            score(track, tokens: tokens, foldedQuery: foldedQuery).map { (track, $0) }
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if (lhs.0.date ?? 0) != (rhs.0.date ?? 0) { return (lhs.0.date ?? 0) > (rhs.0.date ?? 0) }
                return lhs.0.displayTitle < rhs.0.displayTitle
            }
            .prefix(limit)
            .map(\.0)
    }

    /// The distinct performers among `tracks` that match the query, best match first.
    static func artists(in tracks: [AudioTrack], query: String, limit: Int = 8) -> [String] {
        let tokens = tokens(query)
        guard !tokens.isEmpty else { return [] }
        let foldedQuery = fold(query)
        var best: [String: (name: String, score: Int)] = [:]
        for track in tracks {
            let name = track.performer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2 else { continue }
            let folded = fold(name)
            guard !folded.isEmpty, tokens.allSatisfy({ folded.contains($0) }) else { continue }
            var score = fieldScore(folded, token: foldedQuery) ?? 0
            if folded == foldedQuery { score += 100 }
            let key = folded
            if let existing = best[key], existing.score >= score { continue }
            best[key] = (name, score)
        }
        return best.values
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
            .prefix(limit)
            .map(\.name)
    }
}
