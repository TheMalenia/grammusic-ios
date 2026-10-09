# TestFlight — What to Test

Paste the text below into App Store Connect → TestFlight → What to Test.

For the search transition fix and release gates, use the
[phone and release checklist](release-checklist-1.1.0.md).

---

This build improves search, lyrics, bottom navigation, selection, and large-chat shuffle.

**Changes**

- Home and Library have top search bars opening the shared Search page. Home uses a
  smaller gap before Recently played. First bottom Search tap opens the page; a second
  tap focuses the top text field.
- Chat, playlist, artist and profile searches stay inside their navigation stack, share
  the bottom controls, and close with X even while typing. Long results scroll behind
  the tabs and mini-player while the last row remains reachable.
  Keyboard focus waits until the search page finishes appearing, reducing competing
  keyboard and navigation animations when opening scoped search.
- Bot searches load more automatically and use bounded retries for transient failures.
  Error messages distinguish connection problems from a bot not responding. There is
  no Open bot in Telegram action.
- The optional Search playlist saves only search songs actually listened to. It is off
  by default, has the usual default-playlist appearance, and supports Clear all.
- Lyrics appear in a preview card under the player. Show lyrics opens the full view.
  Synced lyrics follow playback; leading and trailing blank lines are removed.
- Hold a song for compact selection icons: Select all, Add to playlist, Remove/Hide,
  and X. If any selected chat song is hidden, the action changes to Unhide. Hide and
  Unhide apply immediately; removing playlist songs keeps its confirmation.
- Shuffle starts from loaded chat songs and adds more songs in the background. Current
  and already-played songs stay in place.
- The offline notice is a compact, single-line capsule aligned with the bottom controls.
  Liking and queueing songs no longer show confirmation bars.
- Player source circles open chat and profile music in Library's navigation stack.
  Block and Leave actions belong to the chat/source menu, not individual song menus.

**Please test**

1. Open Search from Home, Library and the bottom button. Type, switch sources/tabs,
   clear text, and close scoped search with X while the keyboard is open.
2. Scroll long lists with and without playback, offline, and at larger text sizes.
   Check the last song is reachable and the mini-player close button works.
3. Search through an inline music bot; scroll to load more, interrupt connectivity,
   and retry. Loaded songs should stay visible if the next page fails.
4. Enable the Search playlist; listen to one search result and skip another quickly.
   Confirm only listened songs appear. Clear it and inspect its empty state.
5. Select songs, deselect one after Select all, add them to a playlist, and cancel
   loading with X. Hide songs and restore a mixed hidden/visible selection.
6. Shuffle a large chat, skip, disable shuffle, and stop while more songs are loading.
7. Open lyrics, seek in the song, change tracks, and test offline embedded lyrics.
8. Play music, lock the phone, use Lock Screen controls, and relaunch. Check offline
   playback, bulk downloads, and playlist/library recency after additions.

Real bot behavior still needs a Telegram account; mock tests cannot confirm its server.

**Known limitation**

Opus and WebM audio cannot play without a supported decoder; unsupported tracks are
marked and skipped.

Send bug reports to **grammusic@proton.me**, including what you tapped and roughly when.
