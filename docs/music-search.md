# Music search

Global search has a **Telegram** tab and one tab for each inline bot the user connects.
All audio results use the same track rows, player, queue and playlist storage. The
Telegram tab retains its Songs, Artists, Chats and Playlists filters. Find-in-playlist
and find-in-chat stay local and show no source or scope chips. Their X closes the page,
including while the keyboard is open. Home and Library have top search shortcuts to the
shared Search tab. Selecting the bottom Search tab opens the page on the first tap;
a repeated tap focuses its top text field. The query and results survive tab changes.

## Connecting a source

Open **Settings → Search → Search sources**, tap **Connect a bot**, enter an inline
bot's username in the dedicated sheet, then tap **Connect bot**. Telegram must
confirm that it is a bot with inline mode enabled.
The same settings are available from the search screen's source-management button.

Each connected bot can have an optional **Display name**. Leave it empty to use
`@username`. The name appears in tabs, the source list and search status;
it does not change the bot's Telegram identity.

The connection field also accepts a fixed query prefix: `@your_music_bot music` connects
`@your_music_bot` and sends `music Halo` when the user searches for `Halo`. The username
is a placeholder for a bot you choose. Prefixes are
applied once to every page and retry. They are not added to the search text displayed
to the user or to other sources' queries. Open a connected bot's **⋯ → Edit source** menu to
change its display name or prefix later. Clearing either field removes that setting.
Existing saved connections continue to load with both settings empty.

Editing a name preserves the default and cached results. Editing the query prefix
invalidates that source's result cache while keeping its tab/default identity.

Tap a row in **Your sources** to set the initial tab when opening global search.
A checkmark identifies the current default.
Connecting a bot does not automatically make it the default. Removing the default
bot falls back to Telegram. Connections and the default belong to the Telegram
account and are erased on local or remote sign-out.

Search queries are sent only to the selected source. Switching tabs preserves the
query and reuses loaded results for that query. A new query invalidates those tab
caches. Requests are debounced; stale responses cannot replace a newer query or
another source's results. Bot results load subsequent pages automatically as the user
approaches the end.
Telegram search retains its explicit **Load more songs** control.
Errors explain timeouts, offline mode and rate limits, with retry and Telegram fallback
actions. A failed next page keeps existing songs visible, and Retry loading retries that
page instead of restarting the search. There is no external Open bot in Telegram action.

Independent bot searches use the user's Saved Messages chat as their private-chat
context. This is a query context only: no result or message is sent. Inline search retries
transient transport failures once. The search controller additionally
uses at most two attempts for bot response timeouts and backend failures, separated by
about 500ms. Transport failures are excluded from this extra retry layer; cancellation,
rate limits, offline errors and unsupported bots are not retried automatically. A 502 means the
bot missed Telegram's response deadline. Using the same context as Telegram removes
an avoidable request difference, but cannot guarantee that a bot will answer.

The source list keeps the default checkmark and bot options separate. Long names
truncate on one line; VoiceOver retains the full name. Connecting and editing use
labelled fields and a bottom action that stays reachable above the keyboard.
The compact selection toolbar contains a count, Select all, Add to playlist, an optional
Remove/Hide/Unhide action, and X, with 44pt touch targets. Closing cancels pending work.
Entering selection shifts the song rows right to reveal selection circles and animates
the bottom actions. The selection toolbar measures its overlap with the mini-player
and offline dock and reserves only that space; full-screen search has no dock
clearance. Exiting reverses the transition; Reduce Motion disables movement.

## Listening and saving

- Tap a song to play it in GramMusic. No Telegram message is sent.
- Tap the row's **＋** button to add it to a playlist.
- Use **⋯** for Favorites, queue, playlist, download and profile actions.
- Hold a song row to enter selection, tap other rows to select them, then use
  **Add to playlist**. Selection is cleared when the query, source or result filter
  changes. **Select all** includes every page of the current source or collection.
  Choose a playlist to start loading; its row shows **Adding to playlist…** while the
  full selection is fetched. Deselecting a song excludes it from the complete selection,
  including if more rows load afterwards. Scoped search fetches the complete chat or
  profile and applies the current query before adding.
- The bulk picker uses the like-button picker's playlist rows and card styling, including
  Favorites and Profile Music. Local additions deduplicate audio and happen only after
  all pages succeed. Cancel stops fetching; a failed request keeps the selection for retry.
  Profile Music writes individual songs to Telegram and refreshes its mirror after success
  or failure, so confirmed remote additions remain visible if a later write fails.
- Swipe a song to add it to the queue.

Only results with an accessible audio file become song rows. Audio documents are
accepted by MIME type or recognized audio extension. Articles, photos and other
non-audio results are not presented as playable songs. Some bots require setup or
membership in Telegram before returning music; GramMusic does not bypass those
requirements.

Inline audio has no source message (`chatId` and `messageId` are zero). Its persistent
remote file reference is retained by `TrackRef`, so it can be resolved after a
relaunch. Telegram-hosted audio uses the existing streaming/download pipeline.
URL-backed audio uses TDLib's `#url#` file-generation protocol: the app downloads and
validates the audio, then installs it into TDLib's file store. This path may require a
full download before playback. Expired links and unsupported formats fail explicitly.

## Search playlist

Settings → Search offers an optional Search playlist, disabled by default. It collects
only search-origin songs actually listened to, including songs queued from search.
Returned results and merely added playlist items do not populate it. It uses the default
playlist icon/menu and empty-state presentation, supports Clear all, and has no Add music
action. Playlist membership changes refresh library recency.

## Code boundaries

- `SearchSourceStore`: persisted bot connections, default and sign-out invalidation.
- `MusicSearchController`: query identity, tab caches, cancellation, errors and paging.
- `InlineMusicSearch`: Saved Messages context and bounded, cancellation-aware retry.
- `MusicSearchFailure`: actionable search status, distinct from transport diagnostics.
- `TelegramService+Search`: source routing, full collections and bot connection validation.
- `TrackCollection`: cancellation-aware offset paging and audio deduplication.
- `NTrackSelection` / `NPlaylistAddition`: full-selection exclusions and fetch-before-commit state.
- `NPlaylistPickerRow`: shared like-button and bulk-picker destination presentation.
- `TDLibTelegramBackend`: Telegram bot validation, inline-media mapping and file generation.
- `BotAudioFileDownload`: external audio response validation and file installation.
- `NSearchView`: search text, tabs, recents and presentation.
- `NSearchResultsView` / `NSearchTrackRow`: shared result layout and actions.
- `NSearchSettingsView`: connect, remove and choose the default.

The hidden legacy chat messaging screen is not part of this feature.

## Verification

```sh
xcodegen generate
xcodebuild -project GramMusic.xcodeproj -scheme GramMusic \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -jobs 1 ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_BATCH_MODE=YES \
  OTHER_SWIFT_FLAGS='$(inherited) -driver-batch-size-limit 25' \
  -only-testing:GramMusicTests test
```

New coverage is in `SearchSourceStoreTests`, `MusicSearchControllerTests`,
`InlineMusicTrackTests`, `BotAudioFileDownloadTests`, `TrackCollectionTests`, `InlineMusicSearchTests` and
`MusicSearchFailureTests`. Existing audio-search,
selection, playlist, account-wipe and playback tests remain applicable.

### Automated verification on October 6, 2026

The clean iPhone 17 simulator build succeeds. All 52 focused search, playlist, selection
and account tests pass, including 26 new tests. The broader suite ran 285 tests with
one failure in the unchanged
`DownloadLaneTests.test_stoppingADownloadPlaybackAlsoNeeds_demotesInsteadOfCancelling`:
it expects the explicit-download flag to be removed, while the existing implementation
retains it for a track that playback still needs. That behavior was not changed by this
search refactor. The clean build retains the repository's two documented concurrency
warnings in `TelegramService`.

The selection follow-up also passes a clean iPhone 17 simulator build and all 56
focused selection, collection, search, playlist and profile tests, including nine new
regressions. The existing production concurrency warnings and unused UI-test stub
warnings remain unchanged. Real Telegram pagination and visual interaction still need
the manual account checks below.

The picker/animation and bot-timeout follow-up passes the simulator build and all
47 focused tests (12 new regressions). Builds use one Xcode job, one active simulator
architecture and Swift batches capped at 25 files. The raw 502 presentation was
reproduced with the real controller and a deterministic failed fetch. Saved Messages
context, bounded retry, cancellation, rate limits and presentation reset are covered
without contacting a bot. The reported live inline-bot timeout still needs an on-device
retest; a bot's server response cannot be confirmed by these fixtures.

The display-name/query-prefix follow-up passes the memory-conscious simulator build
and all 42 focused tests, including six new regressions for legacy decoding, optional
names, editing/default persistence, invalid input, request prefixing across pagination
and retries, and cache invalidation. Live bot behavior still requires manual testing.

The search-settings redesign and dock-clearance follow-up passes the single-job
simulator build and all 36 focused tests. Two new tests host the real SwiftUI selection
modifier: a dock appearing after layout, dock growth/removal, stable geometry and
an already-inset surface without duplicate clearance. The late-dock regression fails
when the fix is disabled and passes with it restored. Interactive simulator UI access
was unavailable; visual approval still needs the in-app checks below.

### Automated verification on October 8, 2026

The simulator build succeeds. The complete `GramMusicTests` target runs 365 tests:
364 pass and the previously documented
`DownloadLaneTests.test_stoppingADownloadPlaybackAlsoNeeds_demotesInsteadOfCancelling`
fails its explicit-download flag assertion. That test and `TelegramService+Downloads`
are unchanged in this UI/search batch. Search controllers, lyrics resolution, selection,
progressive shuffle, shell navigation and dock-layout tests pass. Hosted layout tests
cover native and conventional docks, small/large viewports and accessibility text sizes;
real bot responses and physical-device interaction still need the checks below.

### Manual checks with a Telegram account

1. Confirm Telegram search and local playlist search still behave as before.
2. Connect an available inline music bot of your choice. Confirm one tab
   appears and a repeated connection does not add a duplicate.
3. Give a bot a display name, confirm it appears in the tab and source list, then
   clear it and confirm the username returns. Connect or edit a bot with the `music`
   prefix and verify its result for a known query against `@your_music_bot music <query>` in Telegram.
4. Choose it as the default, close search, reopen global search, then relaunch the app.
5. Search for a song and switch between Telegram and bot tabs. Confirm the text
   stays unchanged and rows belong to the selected source.
6. Play a bot song. Confirm no new message appears in Saved Messages or another chat.
7. Add one song using ＋, then hold/select several and add them to a new playlist.
   Relaunch and play those playlist tracks again.
8. Check queue, Favorites, download and offline playback of a downloaded bot track.
9. Check pagination, rapid query edits, a non-music inline bot, an invalid username,
   and network loss. No previous query's rows should appear as the new query's result.
10. In a chat with more than 100 songs, hold a row, tap **Select all**, then choose a
   playlist. Confirm **Adding to playlist…** appears and the playlist includes songs
   beyond the first page. Repeat in bot search, scoped chat search and profile music.
   Deselect one song after Select all and confirm it is excluded. Interrupt loading and
   retry; local playlists must not receive a partial selection.
11. Remove the default bot and confirm the next search opens Telegram. Sign out and
   confirm another account does not inherit bot connections or their default.

12. Open a chat before playing, start a song, dismiss Now Playing, then hold/select
    several tracks. Confirm Select all, X and Add to playlist stay above the
    mini-player. Repeat with music already playing before opening the chat, in a
    playlist, and with the offline notice visible. Full-screen search should have no
    empty space reserved for a mini-player.

13. Check Home and Library search shortcuts, first/repeated bottom Search taps, and X
    in chat, artist, playlist and profile search while typing. Verify long lists extend
    behind the shared bottom controls and the last row can scroll above them.
14. Enable the Search playlist, play a search song, and verify only listened songs appear.
    Confirm Clear all, the default icon/menu, the normal empty state and no Add music action.
15. Hide selected chat songs, then select a mixture of hidden and visible songs. Confirm
    Unhide appears, restores hidden songs, and does not ask for confirmation.
16. Shuffle a large chat. Playback should begin with loaded songs while fresh pages join
    the remaining shuffle; stopping playback or disabling shuffle must reject late pages.
17. Lose connectivity and check the single-line offline capsule aligns with the bottom
    controls. Retry a bot timeout and confirm retries stop, explain the failure, and retain
    loaded rows when pagination fails.

Demo/mock mode supplies deterministic inline-bot IDs and paginated sample music for
UI testing without querying real bots. It does not validate a real bot's behavior.
