import SwiftUI

/// The Terms of Use, opened from the consent line on `NLoginView`.
///
/// App Review guideline 1.2 requires an app with user-generated content to present its EULA or
/// terms "before registering or logging in", and to say in them that there is no tolerance for
/// objectionable content or abusive users. GramMusic shows content other Telegram users produced,
/// so it is squarely in scope. Consent is given by signing in — the login screen states that above
/// the Continue button and links here; `NLoginView.recordTermsAcceptance()` stamps the version.
///
/// **The text is bundled, not fetched.** A remote agreement can 404 or fail to load on the
/// reviewer's network, and terms that will not open are worse than useless in a review. The hosted
/// copy at `AppConfig.termsOfUseURL` is linked from the bottom as the shareable version.
struct NTermsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Environment(\.theme) private var theme
    @State private var blocks: [TermsBlock]?

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground().ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let blocks {
                            ForEach(blocks) { block in
                                Text(block.text)
                                    .font(block.font)
                                    .foregroundStyle(block.isHeading ? theme.text : theme.text.opacity(0.85))
                                    .padding(.top, block.isHeading ? 8 : 0)
                                    .padding(.leading, block.isBullet ? 12 : 0)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                        }

                        externalLinks
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Terms of Use")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await loadTerms() }
    }

    private var externalLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(theme.hairline).padding(.vertical, 6)
            Link(destination: AppConfig.termsOfUseURL) {
                Label("View Terms of Use online", systemImage: "arrow.up.right.square")
                    .font(.system(size: 14, weight: .medium))
            }
            Link(destination: AppConfig.privacyPolicyURL) {
                Label("View Privacy Policy", systemImage: "hand.raised")
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .tint(theme.accentColor)
    }

    /// Parse the bundled Markdown off the main actor — it is a few KB, but this runs during the
    /// cold-launch frame where the login screen is trying to appear.
    ///
    /// Parsed **per line** rather than handed wholesale to `AttributedString(markdown:)`: the
    /// inline-only parsing option leaves `##` sitting literally in the text, and the full option
    /// collapses the whole document into one run with the structure thrown away. Neither is a
    /// readable agreement, and an unreadable agreement is not one someone can meaningfully accept.
    private func loadTerms() async {
        let parsed: [TermsBlock]? = await Task.detached(priority: .userInitiated) {
            guard let url = Bundle.main.url(forResource: "TermsOfUse", withExtension: "md"),
                  let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return TermsBlock.parse(raw)
        }.value
        blocks = parsed ?? [TermsBlock(text: AttributedString(NTermsSheet.fallbackText),
                                       isHeading: false, isBullet: false)]
    }

    /// Shown only if the bundled file is missing — tapping "Terms of Use" must never open a blank
    /// screen, which reads as the agreement not existing at all.
    private static let fallbackText = """
        GramMusic plays audio from your own Telegram account. The content is created by other \
        Telegram users and is not reviewed before you see it.

        There is no tolerance for objectionable content or abusive users. Every track and chat \
        offers Report, which notifies Telegram, and Block Source, which immediately hides that \
        source everywhere in the app. Blocked sources can be restored in Settings.

        The app is provided as is. See the Terms of Use and Privacy Policy links for the full text.
        """
}

/// One rendered line of the Terms. Markdown is reduced to the three shapes the document actually
/// uses — heading, bullet, paragraph — with inline `**bold**` preserved inside each.
struct TermsBlock: Identifiable {
    let id = UUID()
    let text: AttributedString
    let isHeading: Bool
    let isBullet: Bool

    var font: Font {
        isHeading ? .display(17, .semibold) : .system(size: 15)
    }

    /// Markdown is **hard-wrapped** in the bundled file, so a paragraph arrives as several physical
    /// lines. They are joined back into one block before parsing: rendering each line as its own
    /// `Text` put the 14pt block spacing in the middle of sentences, and — worse — an inline
    /// `**bold**` span that straddles a wrap never parsed, leaving the asterisks on screen.
    /// A blank line, a heading, or a new bullet ends a block; anything else continues it.
    static func parse(_ raw: String) -> [TermsBlock] {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace

        var blocks: [TermsBlock] = []
        var pending: (text: String, isHeading: Bool, isBullet: Bool)?

        func flush() {
            guard let block = pending else { return }
            pending = nil
            guard !block.text.isEmpty else { return }
            let attributed = (try? AttributedString(markdown: block.text, options: options))
                ?? AttributedString(block.text)
            blocks.append(TermsBlock(text: attributed,
                                     isHeading: block.isHeading,
                                     isBullet: block.isBullet))
        }

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                continue
            }

            if trimmed.hasPrefix("#") {
                flush()
                // The document's own `# Terms of Use` is already the navigation title; rendering it
                // too puts the same title on the screen twice.
                guard !(trimmed.prefix(while: { $0 == "#" }).count == 1 && blocks.isEmpty) else {
                    continue
                }
                let body = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                pending = (body, true, false)
                continue
            }

            if trimmed.hasPrefix("- ") {
                flush()
                pending = ("\u{2022}  " + trimmed.dropFirst(2), false, true)
                continue
            }

            if var current = pending {
                current.text += " " + trimmed
                pending = current
            } else {
                pending = (trimmed, false, false)
            }
        }
        flush()

        return blocks
    }
}

extension StorageKeys {
    /// Whether the person using this device has accepted the Terms version the app ships.
    ///
    /// Written by `NLoginView` when they tap Continue on the phone step, under the consent line
    /// that says signing in constitutes agreement. Kept as a *version* rather than a bool so
    /// revised terms can be re-presented rather than silently applied to someone who agreed to
    /// different text.
    static var hasAcceptedCurrentTerms: Bool {
        UserDefaults.standard.integer(forKey: acceptedTermsVersion) >= AppConfig.termsVersion
    }

    static func recordTermsAcceptance() {
        UserDefaults.standard.set(AppConfig.termsVersion, forKey: acceptedTermsVersion)
    }
}
