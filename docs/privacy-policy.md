# Privacy Policy for GramMusic

**Last Updated: October 8, 2026**

GramMusic ("we", "our", or "the App") is an independent third-party audio player client built on top
of the official Telegram API (TDLib framework). We are not affiliated with Telegram. This Privacy
Policy explains how your information is handled when you use GramMusic.

## 1. Telegram Account & Data

GramMusic interacts directly with Telegram's servers via the official TDLib library to display your
audio messages, channels, and playlists.

**Authentication.** Your phone number, verification codes, and two-factor password are transmitted
directly to Telegram's official servers over Telegram's own encrypted protocol. GramMusic never
intercepts, stores, or sends your authentication credentials to any server we operate. We operate no
server of our own for user data.

**Chats & audio files.** Audio tracks, chat lists, and playlists are fetched directly from your
authorized Telegram account and cached locally on your device for fast playback and offline
listening. We do not host, store, or copy your messages, contact lists, or audio files.

**What GramMusic writes to your Telegram account.** GramMusic never messages your contacts, posts to
chats, or sends spam. It changes your Telegram account only when you explicitly ask it to, and only
in these ways:

- adding, removing, or reordering tracks on your own public profile music;
- joining a channel you chose to join;
- submitting a content report;
- blocking a user, or leaving a channel, when you block a source in the app.

Your recently played tracks and cover artwork are also shared with the GramMusic home-screen widget
through a private app group container on your device. This data does not leave your device.

### Connected music bots

Connecting an inline music bot is optional. When you search its tab, your search text is
sent to that bot through your Telegram account and is subject to Telegram's and the bot
operator's data practices. Other connected bots do not receive that search. If a bot
returns an external audio URL, playback or downloading requests the file directly from
that host, which receives your IP address and ordinary request information. Listening
and adding results to local playlists do not send a Telegram message.

Bot connections and the default search source are stored locally and erased on sign-out.

## 2. Analytics & Crash Diagnostics

To diagnose bugs and maintain app stability we use Google Firebase Crashlytics and Firebase
Analytics. These collect crash reports and stack traces, device and OS information, app version, and
aggregated feature-usage events.

Firebase assigns a randomly generated app-instance identifier to your installation and processes
your IP address, which means this data is **pseudonymous rather than fully anonymous**. It is not
linked to your name, your phone number, your Telegram account, or any of your Telegram content, and
we do not use it to build an advertising profile or to identify you personally. This data is
processed by Google as described in Google's own privacy policy.

## 3. Metadata & Artwork Retrieval

To show high-resolution album covers and lyrics, the App sends media metadata from your device
directly to public music-metadata providers:

- **Apple's iTunes Search API** — receives the track title and artist name, to find album artwork.
- **LRCLIB** — receives the track title, artist name, and track duration, to find lyrics.

These requests contain no user identifiers, account details, or personal data, and they are made
directly from your device. They are not made at all when the App is offline, and lyrics lookups stop
entirely if you turn lyrics off in Settings. Lyrics from LRCLIB are preferred when available;
lyrics embedded in the audio file are used when the lookup finds nothing or the App is offline.

We do not track, profile, or monitor your listening history, and your listening history is never
sent off your device.

## 4. Data Storage, Retention & Deletion

**Local storage.** Cached audio tracks, album artwork, lyrics, playlists, and app settings are stored
locally in your device's app sandbox.

**Data removal.** Logging out erases the data belonging to that Telegram account from your device,
including playlists, recently played tracks, play counts, search history, and caches. You can also
clear cached audio at any time in Settings ▸ Storage, or remove everything by deleting the app.

**Account deletion.** GramMusic does not operate user accounts of its own, so there is no GramMusic
account to delete. Your Telegram account is managed and deleted through Telegram's official
deactivation portal at my.telegram.org, linked from Settings ▸ Account.

## 5. User-Generated Content, Reporting & Blocking

The audio, titles, and chat names shown in GramMusic are created and shared by other Telegram users.
We do not screen this content before you see it. There is **no tolerance for objectionable content
or abusive users**.

**Reporting.** Every track and every chat offers a Report action, which submits the content to
Telegram's native moderation and DMCA systems for review and takedown.

**Blocking and leaving.** Every track and every chat offers an action to remove its source. **Block
User** blocks a person or bot on Telegram and hides everything from them in the app. **Leave
Channel / Leave Group** applies where Telegram does not permit blocking a chat: it leaves the chat
on Telegram and removes it here. **Hide from Library** simply clears a chat from your library view
and can be undone from the import screen. In every case the content leaves your view immediately —
library, search, home screens and the current play queue.

We review reporting and blocking activity to identify abusive sources and act on it.

Your use of the App is also governed by our Terms of Use.

## 6. Children's Privacy

GramMusic is not directed at children and does not knowingly collect or solicit personal information
from children under the age of 13.

## 7. Changes to This Policy

We may update this Privacy Policy from time to time. Any changes will be posted on this page with an
updated revision date.

## 8. Contact Us

Questions or concerns about this Privacy Policy: **grammusic@proton.me**
