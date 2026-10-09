import SwiftUI

/// Settings (screens §5): account header, Appearance (5 theme cards + 7 accent dots, live),
/// Playback, Storage, About, Log out. Switching theme/accent here repaints the whole app.
struct NSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings
    @Environment(TelegramService.self) private var telegram
    @Environment(PlayerEngine.self) private var player
    @Environment(ImportStore.self) private var importStore

    @State private var streaming = AppConfig.useStreaming
    @State private var cacheBytes: Int64 = 0
    @State private var confirmLogout = false
    @State private var showDownloads = false
    @State private var showHiddenSongs = false
    @State private var showEqualizer = false
    @State private var showSearchSettings = false
    @State private var cacheBudgetGB = 2

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.display(33)).tracking(-0.6).foregroundStyle(theme.text)
                    .padding(.top, 8)

                accountCard
                appearance
                searchSettings
                playback
                storage
                community
                privacyAndSafety
                about
                account
                logout
            }
            .padding(.horizontal, 16)
            .nMiniPlayerClearance(player.current != nil, offline: telegram.isOfflineStable, base: 24)
        }
        .background(ScreenBackground())
        .modifier(NScrollDockViewport())
        .task {
            await telegram.loadAccount()
            cacheBytes = await telegram.calculateTotalCacheBytes()
            cacheBudgetGB = max(1, Int(telegram.audioCache.budget / (1024 * 1024 * 1024)))
            await telegram.refreshCommunityMembership()
        }
        .onAppear { AnalyticsService.logOpenSettings() }
        .sheet(isPresented: $showHiddenSongs) { NHiddenSongsView() }
        .sheet(isPresented: $showDownloads) { NDownloadsSheet() }
        .sheet(isPresented: $showSearchSettings) { NSearchSettingsView() }
        .sheet(isPresented: $showEqualizer) { NEqualizerSheet() }
        .alert("Log out of Telegram?", isPresented: $confirmLogout) {
            Button("Log Out", role: .destructive) {
                // Stopping playback and clearing imported chats is handled by the service's
                // onSessionEnded hook, shared with the remote-sign-out path so the two can't drift.
                Task { await telegram.logOut() }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes your playlists, downloads, imported chats, and listening history from this device.") }
    }

    private var searchSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SGroupHeader("Search")
            Button { showSearchSettings = true } label: {
                SRowLabel(icon: "magnifyingglass", tint: theme.accentColor, title: "Search settings",
                          detail: telegram.searchSources.defaultSource.label, chevron: true, singleLineDetail: true)
            }
            .buttonStyle(.plain)
            .nocturneGlassCard(theme)
        }
    }

    // MARK: Privacy & Safety

    /// The agreements, kept somewhere findable rather than only on the login screen.
    ///
    /// The moderation *controls* live where the content is — Report, Leave/Block and Hide on each
    /// track and chat — rather than as a management list here.
    private var privacyAndSafety: some View {
        VStack(alignment: .leading, spacing: 10) {
            SGroupHeader("Privacy & Safety")
            VStack(spacing: 0) {
                Button { showHiddenSongs = true } label: {
                    SRowLabel(icon: "eye.slash", tint: theme.accentColor, title: "Hidden songs",
                              detail: "\(telegram.hiddenTracks.tracks.count)", chevron: true)
                }
                .buttonStyle(.plain)
                SDivider()
                Link(destination: AppConfig.termsOfUseURL) {
                    SRowLabel(icon: "doc.text.fill", tint: .gray, title: "Terms of Use", chevron: true)
                }
                .buttonStyle(.plain)
                SDivider()
                Link(destination: AppConfig.privacyPolicyURL) {
                    SRowLabel(icon: "lock.shield.fill", tint: .gray, title: "Privacy Policy", chevron: true)
                }
                .buttonStyle(.plain)
            }
            .nocturneGlassCard(theme)
            Text("Report messages from their song menu. Leave and Block are in chat menus. Restore hidden songs here, and hidden chats from the import screen.")
                .font(.system(size: 12.5)).foregroundStyle(theme.text3).padding(.horizontal, 4)
        }
    }

    // MARK: Account

    private var accountCard: some View {
        HStack(spacing: 14) {
            Group {
                if let data = telegram.account?.photo, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else {
                    LogoTile(size: 62)
                }
            }
            .frame(width: 62, height: 62).clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(telegram.account?.name ?? "GramMusic").font(.display(21, .semibold)).foregroundStyle(theme.text)
                Text(accountSubtitle).font(.system(size: 13.5)).foregroundStyle(theme.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .nocturneGlassCard(theme)
    }

    private var accountSubtitle: String {
        var parts: [String] = []
        if let p = telegram.account?.phone, !p.isEmpty { parts.append(p) }
        if let u = telegram.account?.username, !u.isEmpty { parts.append("@\(u)") }
        return parts.isEmpty ? (telegram.connectionState.label ?? "Connected") : parts.joined(separator: " · ")
    }

    // MARK: Appearance

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 12) {
            SGroupHeader("Appearance")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ThemeMode.allCases) { mode in
                        NThemePreviewCard(mode: mode, accent: settings.accent, selected: settings.themeMode == mode) {
                            withAnimation(.easeInOut(duration: 0.3)) { settings.themeMode = mode }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Accent color").font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text)
                HStack(spacing: 0) {
                    ForEach(Accent.all) { accent in
                        NAccentDot(accent: accent, selected: settings.accentId == accent.id) {
                            withAnimation(.easeInOut(duration: 0.3)) { settings.accentId = accent.id }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .sensoryFeedback(.selection, trigger: settings.accentId)
            }
            .padding(16)
            .nocturneGlassCard(theme)
        }
    }

    // MARK: Playback

    private var playback: some View {
        VStack(alignment: .leading, spacing: 10) {
            SGroupHeader("Playback")
            VStack(spacing: 0) {
                SToggleRow(icon: "antenna.radiowaves.left.and.right", tint: .blue,
                           title: "Stream while downloading", isOn: $streaming)
                    .onChange(of: streaming) { _, v in AppConfig.useStreaming = v }
                SDivider()
                SToggleRow(icon: "quote.bubble", tint: .teal, title: "Show lyrics",
                           isOn: Binding(get: { settings.lyricsEnabled },
                                         set: { settings.lyricsEnabled = $0 }))
                SDivider()
                SToggleRow(icon: "infinity", tint: .pink, title: "Keep playing",
                           isOn: Binding(get: { player.isAutoplayEnabled },
                                         set: { player.isAutoplayEnabled = $0 }))
                if AppConfig.aiEnabled {
                    SDivider()
                    SToggleRow(icon: "sparkles", tint: .purple, title: "Show AI tab",
                               isOn: Binding(get: { settings.aiTabEnabled },
                                             set: { settings.aiTabEnabled = $0 }))
                }
                SDivider()
                Button {
                    showEqualizer = true
                } label: {
                    SRowLabel(icon: "slider.vertical.3", tint: .indigo, title: "Equalizer",
                              detail: player.isEqualizerEnabled ? player.equalizerPreset.rawValue : "Off",
                              chevron: true)
                }
                .buttonStyle(.plain)
            }
            .nocturneGlassCard(theme)
        }
    }

    // MARK: Storage

    private var storage: some View {
        @Bindable var telegram = telegram
        return VStack(alignment: .leading, spacing: 10) {
            SGroupHeader("Storage")
            VStack(spacing: 0) {
                // Downloads the user chose to keep. Permanent, never evicted.
                Button { showDownloads = true } label: {
                    SRowLabel(icon: "arrow.down.circle.fill", tint: .green, title: "Downloaded",
                              detail: "\(telegram.downloadedIds.count) tracks", chevron: true)
                }
                .buttonStyle(.plain)
                SDivider()

                SToggleRow(icon: "arrow.down.to.line", tint: .green, title: "Keep everything I play",
                           isOn: $telegram.autoDownloadPlayed)

                if !telegram.autoDownloadPlayed {
                    SDivider()
                    SPickerRow(icon: "externaldrive", tint: .blue, title: "Cache limit") {
                        Picker("", selection: $cacheBudgetGB) {
                            ForEach(Self.budgetOptions, id: \.self) { gb in
                                Text("\(gb) GB").tag(gb)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .tint(theme.accentColor)
                    }
                    .onChange(of: cacheBudgetGB) { _, gb in
                        telegram.setAudioCacheBudget(Int64(gb) * 1024 * 1024 * 1024)
                        Task { cacheBytes = await telegram.calculateTotalCacheBytes() }
                    }
                }

                SDivider()
                Button {
                    Task {
                        telegram.clearAudioCache()          // cached audio
                        await telegram.clearAllCaches()     // artwork, lyrics, JSON
                        let newBytes = await telegram.calculateTotalCacheBytes()
                        withAnimation { cacheBytes = newBytes }
                    }
                } label: {
                    SRowLabel(icon: "trash", tint: .gray, title: "Clear cache",
                              detail: byteLabel(cacheBytes + telegram.cachedAudioBytes),
                              chevron: false)
                }
                .buttonStyle(.plain)
            }
            .nocturneGlassCard(theme)

            // One explanation for the whole group, in the footer position iOS settings use —
            // rather than a second line of prose squeezed into the toggle row.
            Text(telegram.autoDownloadPlayed
                 ? "Everything you play is kept in Downloaded until you remove it."
                 : "Music you play is cached so it replays instantly offline, and is cleared automatically to stay under the limit. Downloads you choose are kept.")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text2)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let budgetOptions = [1, 2, 5, 10, 20]

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Community

    /// The app's own Telegram channel. Shows a Join button until we know the user is a member;
    /// once they are (or if the lookup fails), it's a plain "open in Telegram" row — a Join
    /// button we can't stand behind is worse than none.
    private var community: some View {
        VStack(alignment: .leading, spacing: 10) {
            SGroupHeader("Community")
            VStack(spacing: 0) {
                Button {
                    telegram.openCommunityChannel()
                } label: {
                    SRowLabel(icon: "paperplane.fill", tint: Color(hex: 0x2AABEE),
                              title: "Our Channel",
                              detail: "@\(AppConfig.communityChannelUsername)", chevron: true)
                }
                .buttonStyle(.plain)

                if telegram.communityMembership == .notMember {
                    SDivider()
                    Button {
                        Task { await telegram.joinCommunityChannel() }
                    } label: {
                        SRowLabel(icon: "person.badge.plus", tint: Color(hex: 0x2AABEE),
                                  title: telegram.isJoiningCommunity ? "Joining…" : "Join channel",
                                  chevron: false)
                    }
                    .buttonStyle(.plain)
                    .disabled(telegram.isJoiningCommunity)
                }
            }
            .nocturneGlassCard(theme)
            Text("News, releases and fixes — announced there first.")
                .font(.system(size: 12.5)).foregroundStyle(theme.text3).padding(.horizontal, 4)
        }
        .animation(.snappy, value: telegram.communityMembership == .notMember)
    }

    // MARK: About

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            SGroupHeader("About")
            VStack(spacing: 0) {
                SRowLabel(icon: "info.circle.fill", tint: .blue, title: "Version", detail: appVersion, chevron: false)
            }
            .nocturneGlassCard(theme)
            Text("GramMusic never messages your contacts. It only changes your Telegram account when you ask it to — profile music, joining a channel, reporting or blocking a source.")
                .font(.system(size: 12.5)).foregroundStyle(theme.text3).padding(.horizontal, 4)
        }
    }

    // MARK: Account

    /// Telegram accounts are created and deleted on Telegram itself — GramMusic is only a
    /// client. Deletion therefore links out to Telegram's web deactivation page (same pattern
    /// as other third-party clients), rather than calling TDLib's destructive `deleteAccount`.
    private var account: some View {
        VStack(alignment: .leading, spacing: 10) {
            SGroupHeader("Account")
            VStack(spacing: 0) {
                Link(destination: URL(string: "https://my.telegram.org/auth?to=delete")!) {
                    SRowLabel(icon: "person.crop.circle.badge.xmark", tint: Color(hex: 0xFF453A),
                              title: "Delete account", chevron: true)
                }
                .buttonStyle(.plain)
            }
            .nocturneGlassCard(theme)
            Text("GramMusic can't delete your Telegram account — manage or delete it on Telegram's website.")
                .font(.system(size: 12.5)).foregroundStyle(theme.text3).padding(.horizontal, 4)
        }
    }

    private var logout: some View {
        Button(role: .destructive) { confirmLogout = true } label: {
            Text("Log out").font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 50).foregroundStyle(Color(hex: 0xFF453A))
        }
        .nocturneGlassCard(theme)
    }
}

// MARK: - Settings building blocks

private struct SGroupHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    init(_ t: String) { title = t }
    var body: some View {
        Text(title.uppercased()).font(.system(size: 12.5, weight: .semibold)).tracking(0.6)
            .foregroundStyle(theme.text2).padding(.horizontal, 4)
    }
}

private struct SDivider: View {
    @Environment(\.theme) private var theme
    var body: some View { Rectangle().fill(theme.hairline).frame(height: 0.5).padding(.leading, 58) }
}

/// Icon-tile + title + optional detail + optional chevron (one row's content).
private struct SRowLabel: View {
    @Environment(\.theme) private var theme
    let icon: String, tint: Color, title: String
    var detail: String? = nil
    var chevron: Bool = true
    var singleLineDetail = false
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint)
                .frame(width: 30, height: 30)
                .overlay { Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white) }
            Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
                .layoutPriority(singleLineDetail ? 1 : 0)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.system(size: 15)).foregroundStyle(theme.text2)
                    .lineLimit(singleLineDetail ? 1 : nil).truncationMode(.middle)
            }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text3) }
        }
        .padding(.horizontal, 14).frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// A settings row with a trailing control (a menu picker), laid out on the same 30pt icon +
/// 12pt gutter grid as `SRowLabel` so the group's rows line up.
private struct SPickerRow<Control: View>: View {
    @Environment(\.theme) private var theme
    let icon: String, tint: Color, title: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint)
                .frame(width: 30, height: 30)
                .overlay { Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white) }
            Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14).frame(minHeight: 50)
    }
}

private struct SToggleRow: View {
    @Environment(\.theme) private var theme
    let icon: String, tint: Color, title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint)
                .frame(width: 30, height: 30)
                .overlay { Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white) }
            Toggle(title, isOn: $isOn).font(.system(size: 16)).tint(theme.accentColor)
        }
        .padding(.horizontal, 14).frame(minHeight: 50)
    }
}

private struct NThemePreviewCard: View {
    @Environment(\.theme) private var envTheme
    @Environment(\.colorScheme) private var scheme
    let mode: ThemeMode
    let accent: Accent
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let t = mode.resolve(systemScheme: scheme, accent: accent, brand: .nocturne, artwork: .gradient)
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(t.bg)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(t.elev2).frame(width: 44, height: 10)
                        Capsule().fill(accent.color).frame(width: 30, height: 10)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(accent.color).frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Capsule().fill(t.text.opacity(0.7)).frame(width: 34, height: 6)
                                Capsule().fill(t.text2).frame(width: 24, height: 5)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(width: 88, height: 116)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(selected ? accent.color : envTheme.hairline, lineWidth: selected ? 2.5 : 0.5)
                }
                Text(mode.label).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? accent.color : envTheme.text2).lineLimit(1)
            }
        }
        .buttonStyle(NPressable(scale: 0.95))
    }
}

private struct NAccentDot: View {
    let accent: Accent
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle().fill(accent.color).frame(width: 34, height: 34)
                .overlay { if selected { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white) } }
                .overlay { Circle().strokeBorder(accent.color.opacity(selected ? 0.5 : 0), lineWidth: 2).padding(-4) }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(NPressable(scale: 0.85))
        .accessibilityLabel(accent.name)
    }
}

extension View {
    /// Rounded elevated container (grouped-list card) with hairline. (Components §Grouped list.)
    func nocturneGlassCard(_ theme: AppTheme) -> some View {
        background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.elev))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5) }
    }
}
