import Foundation

/// Loose name matching for user-typed text against library names.
///
/// This exists because the names on both sides are messy in the same ways. Telegram performers
/// arrive as `Hendooneh - هندونه`, chat titles carry emoji and decoration, and the user types
/// "radiohead" for "Radiohead" and "lofi" for "LoFi Beats HQ". Exact comparison fails on all of
/// those; a full fuzzy-distance library is more than the job needs.
///
/// Scores are `0...1` and only ever compared against each other, never interpreted as a
/// probability.
enum TextMatch {

    /// Case-, diacritic- and punctuation-insensitive form used for every comparison.
    /// `"Björk!"` and `"bjork"` normalize to the same string.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Normalized whitespace-separated words, with very short noise words dropped.
    static func tokens(_ text: String) -> [String] {
        normalized(text)
            .split(separator: " ")
            .map(String.init)
            .filter { !stopWords.contains($0) }
    }

    /// Words too common to carry meaning in a name match. Kept deliberately tiny — an aggressive
    /// list would eat real band names ("The The", "Yes").
    private static let stopWords: Set<String> = ["the", "a", "an", "of", "and"]

    /// How well `query` identifies `candidate`, `0` meaning no match at all.
    ///
    /// The ladder is ordered by how much confidence each rung deserves: an exact normalized
    /// equality is unambiguous, a whole-token prefix is nearly so, and shared-token overlap is a
    /// guess that gets scored down accordingly.
    static func score(_ query: String, against candidate: String) -> Double {
        let q = normalized(query)
        let c = normalized(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }

        if q == c { return 1.0 }

        let qTokens = tokens(query)
        let cTokens = tokens(candidate)
        guard !qTokens.isEmpty, !cTokens.isEmpty else { return 0 }

        // "lofi beats" inside "lofi beats hq" — every word the user said is present, in order.
        if c.hasPrefix(q + " ") { return 0.95 }
        if c.contains(" " + q + " ") || c.hasSuffix(" " + q) { return 0.9 }

        let qSet = Set(qTokens)
        let cSet = Set(cTokens)
        let shared = qSet.intersection(cSet)
        guard !shared.isEmpty else {
            // Last resort: a single long query word that prefixes a candidate word ("radio" →
            // "radiohead"). Short fragments are refused — "in" must not match "Interpol".
            if qTokens.count == 1, let word = qTokens.first, word.count >= 4,
               cTokens.contains(where: { $0.hasPrefix(word) }) {
                return 0.55
            }
            return 0
        }

        // Proportion of the *user's* words that landed, lightly penalised when the candidate
        // carries a lot of extra words the user didn't say.
        let coverage = Double(shared.count) / Double(qSet.count)
        let precision = Double(shared.count) / Double(cSet.count)
        return 0.5 * coverage + 0.3 * precision
    }

    /// Score at or above which a match is trusted without asking the user to confirm.
    static let confidentThreshold = 0.6

    /// The best-scoring candidate at or above `minimum`, or `nil`.
    /// Ties resolve to the shorter candidate — "Radiohead" beats "Radiohead Live Bootlegs".
    static func best(_ query: String, in candidates: [String],
                     minimum: Double = confidentThreshold) -> String? {
        var winner: (name: String, score: Double)?
        for candidate in candidates {
            let s = score(query, against: candidate)
            guard s >= minimum else { continue }
            guard let current = winner else { winner = (candidate, s); continue }
            if s > current.score || (s == current.score && candidate.count < current.name.count) {
                winner = (candidate, s)
            }
        }
        return winner?.name
    }

    /// Every candidate whose *name* appears somewhere in `text`, best match per candidate.
    ///
    /// This is the inverse direction of `best` and it's what makes the heuristic Composer work:
    /// rather than parsing English grammar, scan the sentence for names we already know exist.
    /// "make me something chill from radiohead and lofi beats" needs no grammar — two roster
    /// names are simply present in it.
    static func mentions(of candidates: [String], in text: String) -> [String] {
        let haystack = " " + normalized(text) + " "
        return candidates.filter { candidate in
            let needle = normalized(candidate)
            guard needle.count >= 3 else { return false }
            return haystack.contains(" " + needle + " ")
                || haystack.contains(" " + needle + "s ")   // simple plural/possessive tolerance
        }
    }
}
