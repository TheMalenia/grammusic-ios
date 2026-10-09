import SwiftUI

/// One-time invitation to the app's own Telegram channel (`@GramMusicApp`).
///
/// Shown **once per account**, and only when we actually know the user isn't a member yet
/// (`TelegramService.shouldShowCommunityPrompt` — an unknown membership doesn't qualify, so a
/// failed lookup can't nag someone who already joined). It is always skippable: dismissing
/// counts as "seen", and the channel stays reachable from Settings ▸ Community afterwards.
struct NJoinChannelView: View {
    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onDone: () -> Void

    @State private var didJoin = false
    @State private var joinFailed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScreenBackground()

            Button { onDone() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.text2).frame(width: 36, height: 36)
                    .background(Circle().fill(theme.scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 18).padding(.top, 14).zIndex(1)
            .accessibilityLabel("Close")

            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 24)
                    mark
                    headline
                    benefits
                    Color.clear.frame(height: 180) // footer breathing room
                }
                .padding(.horizontal, 26)
                .frame(maxWidth: .infinity)
            }

            footer
        }
    }

    // MARK: Header

    private var mark: some View {
        ZStack {
            Circle()
                .fill(theme.accentColor.opacity(0.14))
                .frame(width: 116, height: 116)
            PlaneMark()
                .fill(theme.accentColor)
                .frame(width: 52, height: 52)
        }
        .overlay(alignment: .bottomTrailing) {
            if didJoin {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(theme.accentText, theme.accentColor)
                    .offset(x: -6, y: -4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: didJoin)
    }

    private var headline: some View {
        VStack(spacing: 10) {
            Text(didJoin ? "You're in" : "Join our Telegram channel")
                .font(.display(28, .bold))
                .tracking(-0.6)
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
            Text(didJoin
                 ? "Thanks for joining @\(AppConfig.communityChannelUsername). See you there."
                 : "@\(AppConfig.communityChannelUsername) is where new releases, fixes and tips land first.")
                .font(.system(size: 15.5))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var benefits: some View {
        VStack(spacing: 0) {
            benefitRow("sparkles", "New features first", "Hear about what's shipping before it lands.")
            Rectangle().fill(theme.hairline).frame(height: 0.5).padding(.leading, 58)
            benefitRow("bolt.badge.clock", "Fixes and status", "Know when something's broken — and when it's fixed.")
            Rectangle().fill(theme.hairline).frame(height: 0.5).padding(.leading, 58)
            benefitRow("bubble.left.and.bubble.right", "Tips and requests", "Ask for what you want built next.")
        }
        .nocturneGlassCard(theme)
    }

    private func benefitRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.accentColor)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(theme.text)
                Text(detail).font(.system(size: 13)).foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            if joinFailed && !didJoin {
                Text("Couldn't join from here — opening Telegram works too.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
            }

            if didJoin {
                Pill(title: "Open channel", variant: .primary, size: .lg, fullWidth: true) {
                    telegram.openCommunityChannel()
                }
                Pill(title: "Done", variant: .light, size: .lg, fullWidth: true) { onDone() }
            } else {
                Pill(title: telegram.isJoiningCommunity ? "Joining…" : "Join channel",
                     systemImage: telegram.isJoiningCommunity ? nil : "paperplane.fill",
                     variant: .primary, size: .lg, fullWidth: true) {
                    join()
                }
                .disabled(telegram.isJoiningCommunity)

                Button("Not now") { onDone() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .buttonStyle(.plain)
                    .frame(height: 32)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 34)
        .background {
            LinearGradient(colors: [theme.bg.opacity(0), theme.bg],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
    }

    // MARK: Actions

    private func join() {
        Task {
            let joined = await telegram.joinCommunityChannel()
            withAnimation(reduceMotion ? nil : .snappy) {
                didJoin = joined
                joinFailed = !joined
            }
            // A join that TDLib refused (offline, a restriction) is still recoverable by hand —
            // hand the user to Telegram rather than leaving a dead button.
            if !joined { telegram.openCommunityChannel() }
        }
    }
}
