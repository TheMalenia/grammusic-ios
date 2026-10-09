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

No Firebase configuration is shipped in the public snapshot. A missing configuration
skips initialization and analytics calls. If using Firebase, download your own iOS client
configuration from its console and regenerate after adding it. Never bundle an Admin SDK
service-account private key. A client Firebase API key identifies a project and is not an
administrator secret, but personal builds should still use their own project.

Never commit `.env`, real xcconfig values, bot tokens, session databases, private keys,
or provisioning profiles. The template’s values are placeholders. Do not upload a real
Telegram session for demo access; the app already has an account-free mock demo.
