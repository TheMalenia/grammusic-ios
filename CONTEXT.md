# GramMusic Context

Domain language for GramMusic — a native iOS music player over the user's own Telegram audio.
This file pins terms that are easy to confuse or that name a deliberate architectural seam, so
reviews and grilling sessions share one vocabulary.

## Language

### Track identity & resolution

**Track attribute**:
A piece of derived, cacheable data *about* an `AudioTrack` that is fetched lazily and reused —
cover art, lyrics, an artist cover, a chat photo. Not stored on the track itself.

**Resolver**:
The module that turns a key into a **Track attribute** through a fixed spine — memory tier →
optional disk tier → produce-from-source → cache back → miss-track → in-flight coalesce. One
`Resolver` instance per attribute kind; differences (disk namespace, value codec, whether misses
are tracked) are constructor parameters, not separate code paths.
_Avoid_: cache (too generic), manager, loader.

**Artwork store**:
The seam behind a `Resolver`'s disk tier — `data(for:)` / `store(_:for:)` / `remove` / `clear`,
async. The real adapter writes to `Caches/Artwork/<namespace>`; a test fake holds an in-memory
dict. `ArtworkDiskCache` is the disk adapter, not the seam itself.
_Avoid_: disk cache (that's one adapter), persistence.

**Namespace**:
The versioned (`-vN`) on-disk bucket an **Artwork store** writes into. Bumping the version
abandons entries written by older, possibly-buggy resolution logic.

### Cover art (two-tier)

**Final cover**:
The best-possible cover for a track — embedded full-res art from the downloaded file, else a
iTunes match. Never improves once found; always wins; persisted under `covers-v2`.

**Provisional cover**:
Telegram's own small thumbnail, shown until a **Final cover** exists. Never blocks the upgrade;
persisted under `thumbs-v2`.

### Audio DSP & Equalizer

**Biquad Filter**:
A 2nd-order Direct Form II recursive digital audio filter calculated per frequency band (low-shelf,
peaking, high-shelf) within `AudioLevelTap` on the real-time audio thread.

**Equalizer Preset**:
A fixed profile of 5-band gain adjustments (in dB) representing audio profiles (`.bassBooster`,
`.vocal`, `.electronic`, `.rock`, `.acoustic`, `.flat`, `.custom`).

### Social & Extensions

**Share Card**:
A rendered 1080x1920 graphic representation of track metadata or synchronized lyrics snippet,
formatted for Instagram Stories or system sheet sharing.

**Widget Shared Store**:
The app-group storage coordinator (`group.com.grammusic.app`) synchronizing recently played tracks
and thumbnail images between the main app and the `RecentlyPlayedWidget` extension.

### Music search

**Search source**:
Either Telegram's existing account/library search or an inline bot explicitly connected
by the user. Each source has its own tab; only the selected source receives the query.
A **Search source store** owns the account's connections and default global search source.

**Search page**:
Playable audio references plus a continuation offset and a count of non-audio bot
results. An inline track has no source message, but retains a persistent remote file
reference so the existing player and playlists can resolve it after a relaunch.

**Search controller**:
Owns query/source request identity, debounce, source-specific pages, errors and
pagination. A late result cannot change a different query or source's current rows.
This is separate from `AudioSearch`, which still owns local matching and ranking.

**Search playlist**:
An opt-in, account-local smart playlist of search-origin songs that were actually listened
to, not every result returned. Disabled by default; users can clear it, but cannot manually
add songs to it. It uses the same smart-playlist icon, menus, and empty state as other
default playlists.

**Hidden song**:
A reversible, account-local exclusion from search and playback, distinct from removing
playlist membership or blocking/leaving a Telegram source. Chat selection offers Unhide
whenever any selected song is hidden; mixed selections restore hidden songs without
hiding the visible ones. Hide and Unhide apply without confirmation.

### AI playlist building

**Recipe**:
The structured description of a playlist a user asked for — name, artist names, chat names, moods,
scope, count, sort (`PlaylistRecipe`). It names *entities*, never tracks: a **Composer** cannot put
a song title in a Recipe, so an invented title has nowhere to land.
_Avoid_: prompt, query, request (those are the raw user text).

**Composer**:
Turns the user's sentence plus a **Roster** into a **Recipe** (`PlaylistComposer`). The seam that
makes the language-model provider a swappable detail — `HeuristicComposer` needs no network at all,
a model-backed one needs a key and a proxy, and both satisfy the same protocol.
_Avoid_: parser, agent, assistant (the assistant is the screen, not this).

**Roster**:
The capped list of artist and chat *names* handed to a **Composer** so it can only refer to things
that exist. Names only — never ids, never `remoteUniqueId`s — so nothing in a Roster identifies a
Telegram account.

**Library snapshot**:
The immutable, dependency-free value a **Recipe selector** picks from — tracks by artist, by chat,
favorites, downloads, recently played, play counts. No service, no SwiftData, no main actor, which
is what makes selection testable from a literal.

**Recipe selector**:
Projects a **Recipe** onto a **Library snapshot** to produce a **Selection** (`RecipeSelector`).
Pure and synchronous. Explicitly *not* a **Resolver** — that term is taken by the tiered attribute
lookup and this shares none of its spine (no tiers, no caching, no I/O).

**Selection**:
A **Recipe selector**'s output: the chosen tracks plus what was matched and, crucially, what was
*not* — unmatched names are surfaced to the user rather than silently dropped.

## Relationships

- A **Resolver** reads/writes one or more **Namespaces** through an **Artwork store**.
- The cover resolver is a *composition*: a **Provisional cover** `Resolver` + a **Final cover**
  `Resolver`, with the embedded-art retry and "final wins, drop provisional" policy on top.
- A **Final cover** supersedes a **Provisional cover** for the same track.
- `AudioLevelTap` applies active **Biquad Filters** during playback and reports RMS loudness to `PlayerEngine`.
- `RecentlyPlayedWidget` reads tracks directly from the **Widget Shared Store**.

- A **Composer** reads a **Roster** and writes a **Recipe**; a **Recipe selector** reads that
  **Recipe** against a **Library snapshot** and writes a **Selection**.
- A **Recipe** never contains tracks; only a **Selection** does, and every track in one came from
  the user's own library.

## Example dialogue

> **Dev:** "Does the lyrics **Resolver** need its own miss-tracking, or does the **Artwork store**
> handle that?"
> **Maintainer:** "Miss-tracking lives in the **Resolver** — that's the locality win. The
> **Artwork store** only knows bytes and **Namespaces**; it never decides whether to re-query."

## Flagged ambiguities

- "cache" was used for three distinct things — the in-memory mirror, the disk adapter, and the
  whole tiered lookup. Resolved: the tiered lookup is a **Resolver**, its disk seam is the
  **Artwork store**, and "cache" is reserved for the in-memory tier only.
- "Resolver" was nearly reused for the recipe→tracks stage. Resolved: that stage is a **Recipe
  selector**; **Resolver** stays reserved for the tiered attribute lookup.
