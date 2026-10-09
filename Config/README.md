# Local build configuration

This Swift/Xcode project uses `Secrets.xcconfig`, not a dotenv loader.
Copy `Secrets.example.xcconfig` to `Secrets.xcconfig` and set your own Telegram client
API ID and hash from https://my.telegram.org/apps. The real file is ignored.

| Setting | Required? | Location |
| --- | --- | --- |
| Telegram API ID/hash | Real Telegram only | `Config/Secrets.xcconfig` |
| Inline bot token | No, for the client | Only on your own bot backend, if creating one |
| Firebase client config | Optional | `GramMusic/GoogleService-Info.plist`, ignored |
| Apple team and bundle IDs | Physical device | Your `project.yml`/Xcode signing setup |
| Widget App Group | Shared widgets | Both entitlements and `WidgetSharedStore.appGroupId` |

No Firebase configuration is committed to this repository. A missing configuration
skips initialization and analytics calls. If using Firebase, download your own iOS client
configuration from its console and regenerate after adding it. Never bundle an Admin SDK
service-account private key. A client Firebase API key identifies a project and is not an
administrator secret, but personal builds should still use their own project.

If your local phone build and App Store build use different bundle IDs, register each
as a separate Apple app in the same Firebase project and use its matching configuration.
The existing App Store ID is `com.grammusic.player`; local testing may use
`com.grammusic.app`. Events appearing in Firebase do not by themselves prove the bundle
ID matches. Before archiving, check the archive's bundle ID against `BUNDLE_ID` in the
selected plist. See [Firebase's setup guide](https://firebase.google.com/docs/ios/setup).
The widget extension's bundle ID must also have the current app's bundle ID as its prefix.

Never commit `.env`, real xcconfig values, bot tokens, session databases, private keys,
or provisioning profiles. The template’s values are placeholders. Do not upload a real
Telegram session for demo access; the app already has an account-free mock demo.
