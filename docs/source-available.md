# Publishing GramMusic source

GramMusic makes Telegram audio into an iPhone music library with playlists, search,
offline listening, lyrics, queue controls, and profile music. The README is the primary
public introduction and build guide; it also explains inline bots and their official APIs.

## License

The GramMusic Personal Use Source-Available License permits inspection, personal builds,
private modifications, and personal noncommercial use. Redistribution, organizational or
commercial use, public releases, and services for others require written permission from
an authorized copyright holder at grammusic@proton.me. Proposed patches may be submitted
to the official project under the contribution terms in LICENSE.

This is a custom license chosen to match the personal-use-only requirement. Standard
noncommercial licenses can allow redistribution and organizational uses that do not match
that requirement. This project should be described as **source-available**, not OSI open
source: the [Open Source Definition](https://opensource.org/osd) permits broader use than
this license. Third-party licenses and statutory/platform rights remain separate.

## This repository is a clean source snapshot

**The legacy development history is not included in this repository. Do not publish that legacy history as-is.** The October 9 audit found
hardcoded Telegram client credentials in an obsolete reviewer-session tool and Firebase
client configuration in reachable history. Removing files in a new commit does not remove
old copies. Firebase client keys identify a project rather than granting administrator
access, but the maintainer configuration should not be reused by personal builds.

Replace or revoke the exposed Telegram application credentials through the available
Telegram account/support process. Review Firebase API restrictions and access rules.
Never publish a Telegram session database or a Firebase Admin service-account key.

Maintainers can export another reviewed snapshot from the development repository:

```sh
python3 scripts/export-public-source.py /tmp/grammusic-public-source
```

The exporter copies current files, including eligible uncommitted edits. Review the
snapshot and license before publishing. It excludes `.git`, the generated Xcode project,
private configuration, legacy reviewer tools, design handoffs, and internal review/roadmap
documents. It does not automatically upload, change repository visibility, or rewrite history.

Recommended publication: create a separate empty repository, initialize Git in the
reviewed snapshot, and publish that new history. If preserving the existing public URL is
required, a separately approved history-cleaning operation is needed. Rewriting published
history affects collaborators and does not revoke credentials or erase outside copies.

## What documentation belongs in public source?

Keep README, LICENSE, configuration instructions, domain terminology, search setup,
privacy policy, release notes, demo-media attribution, and the testing checklist. Those
files help people build and understand the software.

CLAUDE.md, design handoffs, App Review correspondence, and internal roadmaps are already
tracked in the maintained repository but are not needed to build a personal copy. They
are omitted from the public snapshot, rather than deleted from the maintained project.
Review any additional document before adding it to the public exporter’s allowlist.

## Build and configuration

See [README](../README.md) and [Config/README](../Config/README.md). The app uses an ignored
`Secrets.xcconfig`, not a dotenv loader. The tracked example contains placeholders only.
Firebase initialization and analytics are optional when no personal configuration exists.
Users supply their own Telegram credentials, Apple signing, and optional Firebase project.

## Limits of the audit

The audit inspected tracked paths and scanned 840 reachable Git blobs for selected key,
private-key, bot-token, and Telegram-credential patterns. It found the historical items
above; no session database, signing private key, or service-account key was identified by
those checks. Pattern scans are not proof that every possible secret has been found.
Repeat a dedicated secret scan before publishing additional history or new files.

## Clean-snapshot verification — October 9, 2026

The exported snapshot generated an Xcode project and built on the iOS Simulator using
only placeholder Telegram values and no Firebase configuration. All four
`ShellNavigationTests` passed, including launch of the unconfigured app test host. The
final export excludes the test setup file and generated project. Selected credential
patterns found no matches in the exported source. This does not validate live Telegram
responses or certify that a pattern scan detects every possible sensitive value.
