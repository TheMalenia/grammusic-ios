# GramMusic 1.1.0 — phone and release checklist

Use the maintained `grammusic-ios` checkout for the build. Record the tested commit,
build number, iPhone model, and iOS version. Test a small playlist and a large chat.

## Search transition regression

- [ ] Tap Find in chat, playlist, artist, and profile playlist. Search opens directly
  without a sideways slide; the keyboard opens after the page appears, without a layout jump.
- [ ] Repeat opening and closing each search ten times, with playback stopped,
  playing, and paused. Watch for flashing backgrounds or duplicated bottom controls.
- [ ] Close immediately during opening, then reopen. No late keyboard appears on
  the previous page. X closes the page in one tap while typing and with the keyboard hidden.
- [ ] Swipe back, including an interrupted swipe. The previous page's scroll position
  and the mini-player remain intact. Reopening search accepts text normally.
- [ ] Search by title and artist; clear the query. Results stay inside the selected
  collection. Hidden tracks stay excluded. Empty collections show their empty state.
- [ ] Scroll long results to the last song. Rows pass behind the bottom controls;
  the last song can still be reached and tapped. Try the largest practical text size.
- [ ] Repeat in light/dark appearance and with Reduce Motion enabled. Test an older
  supported iOS version too if a device is available; the conventional dock must work.
- [ ] Global Search still opens its page on the first tab tap and focuses the top
  field on the second. Home and Library search bars still open global Search.

## Release smoke tests

- [ ] Real Telegram sign-in and relaunch preserve the library and account.
- [ ] Play, pause, skip, seek, stop, background playback, and Lock Screen controls work.
- [ ] Large-chat shuffle starts promptly and continues while loading more tracks.
- [ ] Create a playlist, add/remove songs, follow an artist, and open player source circles.
- [ ] Select songs, close selection with X, hide/unhide, and add several to a playlist.
- [ ] Search using your chosen inline source. Check pagination, bounded automatic
  retry, offline text, reconnection, and cancellation after changing the query.
- [ ] The optional Search playlist records listened songs only and supports Clear all.
- [ ] Lyrics preview/full view, line following, seeking, and track changes work.
- [ ] Download a track, enable airplane mode, and play it. Check the connection notice
  and mini-player spacing, then reconnect.
- [ ] Settings shows version 1.1.0. Widgets still read the shared playback state.

## Prepare the phone build and App Store submission

- [ ] Configure the ignored `Config/Secrets.xcconfig` with real Telegram credentials
  (see [configuration](../Config/README.md)); use the existing app's signing team,
  bundle identifiers, and matching App Group. Generate/open the Xcode project from
  this checkout, not the legacy workspace.
- [ ] Select your connected iPhone in Xcode and run the app. Complete the search
  regression checklist before making the release archive.
- [ ] Keep marketing version 1.1.0 for this planned release. Before uploading, set a
  new build number greater than the latest uploaded build; do not assume build 1 is unused.
- [ ] Run the unit tests on the phone, including `SearchAppearanceTests` and
  `ShellNavigationTests`. The appearance regression checks that keyboard requests
  wait for completed presentation. These tests do not measure animation smoothness.
- [ ] Before archiving, restore the existing App Store bundle ID `com.grammusic.player`
  and its distribution signing team. The `.app` ID is for local phone testing; its
  widget extension must use the same bundle prefix.
- [ ] Use the Firebase configuration registered for the archive's bundle ID. The
  local `.app` configuration does not confirm correct `.player` registration; obtain
  the matching file from Firebase Console. Keep the real file ignored.
- [ ] Archive the Release configuration and validate it in Xcode Organizer. Verify
  real Telegram credentials are configured and no Telegram account session is bundled.
- [ ] Upload via App Store Connect distribution, add the processed build to an
  internal TestFlight group, and install that build on your phone. Repeat the smoke tests.
- [ ] Select the tested build on the 1.1.0 App Store version page, add
  [release notes](release-notes-1.1.0.md), and check review access/demo instructions,
  screenshots, privacy answers, and support links before submitting for review.

Apple references: [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/),
[internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/),
and [version/build numbers](https://help.apple.com/xcode/mac/current/en.lproj/devba7f53ad4.html).

## Verification of this search fix

Scoped search opens directly and closes with X using a transaction that disables
navigation animation. Its Search title and close button stay inside the page, and
collection/search pages keep the system navigation bar hidden. Keyboard focus waits
for completed appearance; results and selection reuse one song-filtering pass.

On October 9, 2026, the maintainer confirmed the issue was fixed on their phone after
switching Xcode to the maintained checkout. The older Xcode window had been using the
legacy repository, so earlier phone reports did not verify this checkout.

The opening/closing transaction passed a standalone SwiftUI binding harness on macOS.
The appearance adapter, transition helper, and new tests passed isolated iPhoneOS SDK
typechecking; changed Swift files passed syntax and whitespace checks. No full app build
or automated device/Simulator test suite was run by the agent for this follow-up.
The earlier full test/build results in [development](development.md) predate this fix.
The remaining release smoke tests, Release archive, and upload still need completion.
