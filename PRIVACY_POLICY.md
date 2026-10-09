# Privacy Policy for GramMusic

**Last Updated:** October 8, 2026

GramMusic ("we", "our", or "the App") is an independent third-party audio player client built on top of the official Telegram API (TDLib framework). We are committed to protecting your privacy. This Privacy Policy explains how your information is handled when you use GramMusic.

---

### 1. Telegram Account & Data

GramMusic interacts directly with Telegram's servers via the official TDLib library to display your audio messages, channels, and playlists:

- **Authentication:** Your phone number, verification codes, and 2FA passwords are encrypted and transmitted directly to Telegram's official servers. GramMusic never intercepts, transmits to external servers, or stores your authentication credentials.
- **Chats & Audio Files:** Audio tracks, chat lists, and playlists are fetched directly from your authorized Telegram account and cached locally on your device for fast playback and offline listening. We do not host, store, or copy your personal messages, contact lists, or audio files on our own servers.
- **Read-Only Operation:** GramMusic operates as a read-only media player. It does not send messages, create spam, or interact with your contacts without your explicit instruction.

---

### Connected music bots

Connecting an inline music bot is optional. When you search its tab, your search text is
sent to that bot through your Telegram account and is subject to Telegram's and the bot
operator's data practices. Other connected bots do not receive that search. If a bot
returns an external audio URL, playback or downloading requests the file directly from
that host, which receives your IP address and ordinary request information. Listening
and adding results to local playlists do not send a Telegram message.

Bot connections and the default search source are stored locally and erased on sign-out.

### 2. Third-Party Analytics & Crash Diagnostics

To improve app performance, diagnose bugs, and maintain app stability, we use trusted analytics and crash reporting services:

- **Firebase Crashlytics & Analytics:** We collect anonymized crash reports, device performance statistics, and aggregated feature usage metrics (such as app version, OS version, and crash stack traces).
- **What we log is the *action*, never the content.** Analytics events record only that something happened — for example that a track was played, a playlist was created, or the search screen was opened. They deliberately carry **no track titles, artist names, chat names, file names, or message contents**. Nothing that identifies the music in your Telegram account leaves your device through analytics.

---

### 3. Metadata & Artwork Retrieval

To enrich your listening experience with high-resolution album covers and synchronized lyrics:

- The App sends non-personal media metadata (specifically track title, artist name, and track duration) directly from your device to public music metadata providers. The providers used are:
  - **Apple's iTunes Search API** — to find high-resolution album and artist artwork. Receives the track title and artist name.
  - **LRCLIB** (`lrclib.net`) — to find song lyrics. Receives the track title, artist name and track duration.
- Because a track's title and artist are read from the audio file in your Telegram chats, be aware that **this metadata is what is sent** when artwork or lyrics are looked up. Each track is looked up at most once per session, results are cached on your device, and **no lookups are made while offline**.
- Lyrics from LRCLIB are preferred when available. Cached lyrics remain available offline; lyrics embedded in a downloaded file are used when the lookup finds nothing or the app is offline.
- **No Personal Identifiers:** These requests contain no user identifiers, account details, or personal data, and they are not linked to your analytics identity.
- **You can turn lyrics off** in Settings, which disables all lyrics lookups.
- Your listening history (recently played, play counts) is kept **on your device only** — we never receive it, and it is deleted when you log out.

---

### 4. Data Storage, Retention & Deletion

- **Local Storage:** All cached audio tracks, album artwork, and custom playlists are stored locally on your device's sandbox storage.
- **Data Removal:** You can clear all cached files and local playlists at any time by logging out or deleting the app from your device.
- **Account Deletion:** Since GramMusic does not operate independent user accounts or external servers, deleting your Telegram account is managed directly via Telegram's official deactivation portal at [my.telegram.org](https://my.telegram.org).

---

### 5. Content Reporting & DMCA Compliance

GramMusic includes a built-in content reporting tool that allows users to report infringing, copyrighted, or inappropriate content directly to Telegram's native moderation and abuse team for prompt review and takedown.

---

### 6. Children's Privacy

GramMusic does not knowingly collect or solicit personal information from children under the age of 13.

---

### 7. Changes to This Policy

We may update our Privacy Policy from time to time. Any changes will be posted on this page with an updated revision date.

---

### 8. Contact Us

If you have any questions or concerns regarding this Privacy Policy, please contact us at:
- **Email:** grammusic@proton.me

