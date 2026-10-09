# GramMusic 1.1.0 — phone and release checklist

Use the maintained `grammusic-ios` checkout for the build. Record the tested commit,
build number, iPhone model, and iOS version. Test a small playlist and a large chat.

## Search transition regression

- [ ] Tap Find in chat, playlist, artist, and profile playlist. The page slides in
  smoothly; the keyboard opens after the page appears, without a second layout jump.
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
- [ ] Archive the Release configuration and validate it in Xcode Organizer. Verify
  real credentials are configured and no Telegram account session is bundled.
- [ ] Upload via App Store Connect distribution, add the processed build to an
  internal TestFlight group, and install that build on your phone. Repeat the smoke tests.
- [ ] Select the tested build on the 1.1.0 App Store version page, add
  [release notes](release-notes-1.1.0.md), and check review access/demo instructions,
  screenshots, privacy answers, and support links before submitting for review.

Apple references: [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/),
[internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/),
and [version/build numbers](https://help.apple.com/xcode/mac/current/en.lproj/devba7f53ad4.html).

## Verification of this search fix

The search field previously requested focus from SwiftUI `onAppear`, during the
navigation push. It now waits for the native completed-appearance callback, without
a fixed delay. Each redraw also shares one song-filtering pass between results and
selection instead of doing the work twice.

The new appearance adapter and its lifecycle test were typechecked against the iPhoneOS
SDK in isolation; changed Swift files passed syntax and whitespace checks. This is not a
full app build or a test run. Simulator and device tests were not run for this change;
the Simulator remains stopped. The earlier test/build results
in [development](development.md) predate this fix. Physical-device animation testing,
the Release archive, and upload remain release gates.
