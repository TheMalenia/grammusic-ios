import Foundation

/// Where a resolved set of lyrics came from. Drives the small attribution footer.
enum LyricsSource: String, Codable, Sendable {
    case embedded   // read from the downloaded audio file (offline, free)
    case lrclib     // fetched from the LRCLIB public API
}

/// One line of lyrics. `time` is the playback offset in seconds for synced (LRC) lyrics, or
/// `nil` for plain lyrics.
struct LyricLine: Hashable, Sendable, Codable {
    let time: Double?
    let text: String
}

/// A resolved set of lyrics for a track — either plain (scrollable) or synced (line-by-line
/// timestamps, enabling karaoke-style highlighting).
struct Lyrics: Hashable, Sendable, Codable {
    var lines: [LyricLine]
    var source: LyricsSource

    /// True when at least one line carries a timestamp, so the UI can highlight/auto-scroll.
    var isSynced: Bool { lines.contains { $0.time != nil } }

    /// Also trims old cached lyrics that predate normalization.
    var displayLines: [LyricLine] { Self.trimBlankEdges(lines) }

    /// Lines that have timestamps, sorted by time — the data the synced view walks.
    var syncedLines: [LyricLine] {
        Self.trimBlankEdges(lines.filter { $0.time != nil }.sorted { ($0.time ?? 0) < ($1.time ?? 0) })
    }

    /// True if the lyrics are primarily right-to-left (e.g. Persian, Arabic, Hebrew).
    var isRTL: Bool {
        let sample = displayLines.prefix(5).map(\.text).joined(separator: " ")
        if let firstLetter = sample.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }) {
            let rtlSet = CharacterSet(charactersIn: "\u{0590}"..."\u{08FF}")
            return rtlSet.contains(firstLetter)
        }
        return false
    }

    /// Parse a raw lyrics string into `Lyrics`. The string may be LRC (with `[mm:ss.xx]`
    /// timestamps — possibly several per line) or plain text. Returns `nil` if there's no
    /// usable text. Embedded file lyrics and LRCLIB results both flow through here.
    static func parse(_ raw: String, source: LyricsSource) -> Lyrics? {
        var lines: [LyricLine] = []
        var sawTimestamp = false

        for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var rest = Substring(rawLine)
            var stamps: [Double] = []
            // Pull all leading `[mm:ss.xx]` tags off the front of the line.
            while let stamp = Self.leadingTimestamp(in: rest) {
                stamps.append(stamp.seconds)
                rest = rest[stamp.endIndex...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            if !stamps.isEmpty {
                sawTimestamp = true
                // A line can carry several timestamps (repeated chorus) → one entry each.
                for t in stamps { lines.append(LyricLine(time: t, text: text)) }
            } else {
                lines.append(LyricLine(time: nil, text: text))
            }
        }

        if sawTimestamp {
            // Drop metadata and order repeated timestamps before trimming the playback edges.
            lines = lines.filter { $0.time != nil }.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
        }
        lines = Self.trimBlankEdges(lines)
        guard !lines.isEmpty else { return nil }
        return Lyrics(lines: lines, source: source)
    }

    /// Verse separators remain intact; only whitespace-only lines at either edge disappear.
    private static func trimBlankEdges(_ lines: [LyricLine]) -> [LyricLine] {
        func hasText(_ line: LyricLine) -> Bool {
            !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let first = lines.firstIndex(where: hasText),
              let last = lines.lastIndex(where: hasText) else { return [] }
        return Array(lines[first...last])
    }

    /// Match a single `[mm:ss]`, `[mm:ss.xx]`, or `[mm:ss:xx]` tag at the start of `s`.
    private static func leadingTimestamp(in s: Substring) -> (seconds: Double, endIndex: Substring.Index)? {
        guard s.first == "[" else { return nil }
        guard let close = s.firstIndex(of: "]") else { return nil }
        let inner = s[s.index(after: s.startIndex)..<close]
        // Split on ':' then handle a trailing `.fraction` on the seconds component.
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let minutes = Double(parts[0]) else { return nil }
        let secPart = parts[1].replacingOccurrences(of: ".", with: ":")
        let secComps = secPart.split(separator: ":", omittingEmptySubsequences: false)
        guard let seconds = Double(secComps[0]) else { return nil }
        var total = minutes * 60 + seconds
        if secComps.count > 1, let frac = Double(secComps[1]) {
            total += frac / pow(10, Double(secComps[1].count))
        }
        return (total, s.index(after: close))
    }
}
