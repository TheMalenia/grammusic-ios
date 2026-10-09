# Developing GramMusic

[TheMalenia/grammusic-ios](https://github.com/TheMalenia/grammusic-ios) is the active
repository for GramMusic. Development continues here on `main`; this is the maintained
project, not a temporary export. New work should be committed to this repository.

## Getting started

Follow the [README build instructions](../README.md#build-your-own-copy). Copy the
configuration template to your ignored `Config/Secrets.xcconfig` and use your own
Telegram credentials when connecting to Telegram. Demo mode works with placeholder
values. Firebase configuration is optional.

## Making changes

1. Work in a checkout of `grammusic-ios`. Use a feature branch and a pull request when
   contributing changes for review.
2. Edit the source directly. `project.yml` defines the Xcode project and dependencies;
   run `xcodegen generate` after adding or removing Swift files or changing the project
   configuration. Do not commit the generated Xcode project.
3. Run checks appropriate to the change. App changes should build and pass the relevant
   tests; check affected screens on a device when changing their behavior or layout.
4. Update the relevant documentation and release notes when behavior changes.
5. Review the files and diff before committing, then push to this repository.

No export script or second development repository is needed. Normal commits preserve
the project's history as it grows.

## Configuration and private data

Real Telegram credentials, Firebase configuration, account sessions, private keys, and
provisioning profiles must stay out of commits. The tracked configuration example contains
placeholders. See [local configuration](../Config/README.md).

Keep bundled font licenses and [demo audio attribution](../GramMusic/Resources/DemoAudio/CREDITS.md).
Dependencies and third-party assets retain their own licenses.

## License and contributions

Copyright (C) 2026 GramMusic contributors.

GramMusic is free software: you can redistribute it and/or modify it under the terms of
the GNU General Public License as published by the Free Software Foundation, either
version 2 of the License, or (at your option) any later version.

GramMusic is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
PURPOSE. See [LICENSE](../LICENSE) for the full GNU General Public License.

The project uses `GPL-2.0-or-later`, following the licensing approach of
[Telegram iOS](https://telegram.org/apps#source-code), from which
[Swiftgram](https://github.com/Swiftgram/Telegram-iOS) is forked. GramMusic is an independent
TDLib-based app, not a fork of either application's codebase.

You may use the app for personal or commercial purposes and make private modifications.
If you distribute a covered app or modified version, comply with the GPL's source-code,
licensing, and notice requirements. The corresponding source must include your changes
and the material needed to build the covered program, subject to the license's exceptions.

The GPL does not require you to commit to our `main` branch or submit a pull request.
We welcome improvements through pull requests to this repository. Contributions must be
submitted under `GPL-2.0-or-later`, and you must have the right to contribute them.
Third-party dependencies, fonts, and demo recordings keep their respective licenses.
This license does not grant rights to other people's music or trademark rights.

## Last verified build — October 9, 2026

- All 367 unit tests and the app-launch UI smoke test passed.
- Debug and Release simulator builds passed without compiler warnings or errors.
- Both app bundles reported version 1.1.0 and built with placeholder Telegram credentials
  and no Firebase client configuration.
- The public commit history was checked for selected credential patterns; no matches were
  found. GitHub secret scanning, push protection, and dependency vulnerability alerts were
  enabled, with no open alerts at the time of checking.

These results describe the checks performed that day. The UI smoke test verifies launch,
not every interaction; live Telegram and physical-device behavior need manual testing.
Use the [manual testing checklist](music-search.md) for affected flows. Builds and tests
do not need to run again for a documentation-only change.
