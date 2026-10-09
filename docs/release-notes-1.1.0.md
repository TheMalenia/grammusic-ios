# GramMusic 1.1.0 release notes

Prepared October 9, 2026. App version: 1.1.0.

## App Store — What’s New in This Version

Copy the text below into the 1.1.0 version’s What’s New in This Version field in
App Store Connect. This is public release copy, separate from TestFlight testing notes.

---

Enjoy a cleaner music experience with improved search, lyrics, and library controls.

• Search from Home or Library, or use the dedicated Search tab. Your query stays with you as you switch tabs.
• Connect Telegram inline music bots as search sources, with custom names, optional query prefixes, automatic loading of more results, and clearer errors with bounded automatic retries.
• Turn on the optional Search playlist to keep songs you actually listen to from search. Clear it whenever you like.
• Follow lyrics in a preview card below the player, then tap Show lyrics for the full view. Lyrics follow playback, with cleaner spacing and fewer empty lines.
• Start shuffling large chats sooner while more songs are loaded into the remaining queue.
• Select songs with compact controls to add them to playlists, remove them from playlists, or hide and unhide chat songs.
• Open chat and profile music directly from the player’s source icon.
• Browse with updated bottom navigation, a closable mini-player, and a compact offline notice.
• Enjoy cleaner search results, playlist pickers, recent lists, and song menus, with fewer interruptions when liking or queueing music.
• Improved playlist recency, search dismissal, and layout at different screen and text sizes.

---

## App Store Connect location

Open Apps → GramMusic → the iOS 1.1.0 version page → What’s New in This Version.
If 1.1.0 does not exist yet, create a new version from the platform’s add-version control.
Enter the release notes for each supported localization and select the uploaded 1.1.0
build before submission.

Apple documents this field in [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
and version creation in [Create a new version](https://developer.apple.com/help/app-store-connect/update-your-app/create-a-new-version).

## Engineering and testing references

- [Search behavior and verification](music-search.md)
- [TestFlight testing checklist](testflight-notes.md)
- [Phone regression tests and release gates](release-checklist-1.1.0.md)
- [Current features](../README.md)

The version number is configured in `project.yml` and synchronized with the current
Xcode project. The build number remains 1. Existing signing and provisioning settings
are preserved. These notes do not indicate that a build has been uploaded or released.
