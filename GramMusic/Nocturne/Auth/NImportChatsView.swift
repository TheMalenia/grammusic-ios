import SwiftUI

/// App-level set of excluded Telegram chat ids, persisted in UserDefaults.
/// The source of truth for which chats are hidden from the rest of the app. 
/// Injected as an `@Environment` object so any screen (e.g. Library) can read/mutate it.
@Observable
@MainActor
final class ImportStore {
    private static let chatKey = "n_removedChats"
    private static let profileKey = "n_removedProfiles"

    private(set) var removedChatIds: Set<Int64>
    private(set) var removedProfileIds: Set<Int64>

    var removedIds: Set<Int64> { removedChatIds }

    init() {
        let rawChats = UserDefaults.standard.array(forKey: Self.chatKey) as? [Int] ?? []
        removedChatIds = Set(rawChats.map(Int64.init))
        let rawProfiles = UserDefaults.standard.array(forKey: Self.profileKey) as? [Int] ?? []
        removedProfileIds = Set(rawProfiles.map(Int64.init))
    }

    func isChatImported(_ id: Int64) -> Bool { !removedChatIds.contains(id) }
    func isProfileImported(_ userId: Int64) -> Bool { !removedProfileIds.contains(userId) }

    func isImported(_ id: Int64) -> Bool { isChatImported(id) }

    func toggleChat(_ id: Int64) {
        if removedChatIds.contains(id) { removedChatIds.remove(id) } else { removedChatIds.insert(id) }
        persist()
    }

    func toggleProfile(_ userId: Int64) {
        if removedProfileIds.contains(userId) { removedProfileIds.remove(userId) } else { removedProfileIds.insert(userId) }
        persist()
    }

    func toggle(_ id: Int64) {
        toggleChat(id)
    }

    /// Hide a chat from the Library, idempotently.
    ///
    /// Distinct from `toggleChat` because the callers that matter — the Hide action and leaving a
    /// channel — mean "make this gone", not "flip whatever state it is in". Toggling an already
    /// hidden chat would *unhide* it, which is precisely the wrong outcome for both.
    func hideChat(_ id: Int64) {
        guard !removedChatIds.contains(id) else { return }
        removedChatIds.insert(id)
        persist()
    }

    func hideProfile(_ userId: Int64) {
        guard !removedProfileIds.contains(userId) else { return }
        removedProfileIds.insert(userId)
        persist()
    }

    func unhideChat(_ id: Int64) {
        guard removedChatIds.contains(id) else { return }
        removedChatIds.remove(id)
        persist()
    }

    func setRemoved(chatIds: Set<Int64>, profileIds: Set<Int64>) {
        removedChatIds = chatIds
        removedProfileIds = profileIds
        persist()
    }

    func setRemoved(_ ids: Set<Int64>) {
        removedChatIds = ids
        persist()
    }

    /// Forget all removed chats and profiles (used on log out).
    func clear() {
        removedChatIds = []
        removedProfileIds = []
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(removedChatIds.map(Int.init), forKey: Self.chatKey)
        UserDefaults.standard.set(removedProfileIds.map(Int.init), forKey: Self.profileKey)
    }
}

/// "Manage chats" screen reached from Library ▸ Chats (X close, "Manage chats", a single "Done").
/// The user picks which audio-bearing chats and user profile playlists to show/hide independently.
struct NImportChatsView: View {
    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    var store: ImportStore
    var onDone: () -> Void = {}

    /// Local working selections (committed to the store on Done).
    @State private var selectedChatIds: Set<Int64> = []
    @State private var selectedProfileIds: Set<Int64> = []
    @State private var hasLoaded = false

    private var chats: [TelegramChat] { telegram.chats.filter { ($0.audioCount ?? 0) > 0 } }
    private var profiles: [UserProfilePlaylist] { telegram.userProfiles }

    private var selectedCount: Int { selectedChatIds.count + selectedProfileIds.count }
    private var totalCount: Int { chats.count + profiles.count }

    private var trackCount: Int {
        let chatTracks = chats.filter { selectedChatIds.contains($0.id) }.reduce(0) { $0 + ($1.audioCount ?? 0) }
        let profileTracks = profiles.filter { selectedProfileIds.contains($0.userId) }.reduce(0) { $0 + $1.trackCount }
        return chatTracks + profileTracks
    }

    private var allSelected: Bool { totalCount > 0 && selectedCount == totalCount }

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

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusRow
                    chatList
                    Color.clear.frame(height: 140) // footer breathing room
                }
                .padding(.horizontal, 22)
                .padding(.top, 24)
            }

            footer
        }
        // Re-runs when chats finish loading (they arrive async, after this view appears).
        .task(id: totalCount) {
            guard !hasLoaded && totalCount > 0 else { return }
            hasLoaded = true
            selectedChatIds = Set(chats.map(\.id).filter { store.isChatImported($0) })
            selectedProfileIds = Set(profiles.map(\.userId).filter { store.isProfileImported($0) })
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage chats")
                .font(.display(26, .bold))
                .tracking(-0.6)
                .foregroundStyle(theme.text)
            Text("Choose which audio-bearing chats and profile playlists appear in your Library.")
                .font(.system(size: 15))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Status row

    private var statusRow: some View {
        HStack {
            Text("\(selectedCount) selected · \(trackCount) tracks")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.text2)
            Spacer()
            Button(allSelected ? "Clear all" : "Select all") {
                withAnimation(reduceMotion ? nil : .snappy) {
                    if allSelected {
                        selectedChatIds.removeAll()
                        selectedProfileIds.removeAll()
                    } else {
                        selectedChatIds = Set(chats.map(\.id))
                        selectedProfileIds = Set(profiles.map(\.userId))
                    }
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.accentColor)
            .buttonStyle(.plain)
        }
    }

    // MARK: Chat list

    private var chatList: some View {
        // Lazy: every row carries an NChatAvatar whose `.task` fetches a chat photo, so an eager
        // stack kicked off one photo fetch per chat at once — on the first-run onboarding screen.
        LazyVStack(spacing: 4) {
            ForEach(chats) { chat in chatRow(chat) }
            ForEach(profiles) { profile in profileRow(profile) }
        }
    }

    private func chatRow(_ chat: TelegramChat) -> some View {
        let on = selectedChatIds.contains(chat.id)

        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                if on { selectedChatIds.remove(chat.id) } else { selectedChatIds.insert(chat.id) }
            }
        } label: {
            HStack(spacing: 12) {
                NChatAvatar(chat: chat, size: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(chat.audioMeta)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.text2)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                checkMark(on: on)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(on ? (theme.scheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.02)) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(NPressable(scale: 0.99))
        .accessibilityLabel(chat.title)
        .accessibilityValue(on ? "Selected" : "Not selected")
    }

    private func profileRow(_ profile: UserProfilePlaylist) -> some View {
        let on = selectedProfileIds.contains(profile.userId)

        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                if on { selectedProfileIds.remove(profile.userId) } else { selectedProfileIds.insert(profile.userId) }
            }
        } label: {
            HStack(spacing: 12) {
                NProfileAvatar(profile: profile, size: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.title)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text("Profile · \(profile.trackCount) track\(profile.trackCount == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.text2)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                checkMark(on: on)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(on ? (theme.scheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.02)) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(NPressable(scale: 0.99))
        .accessibilityLabel(profile.title)
        .accessibilityValue(on ? "Selected" : "Not selected")
    }

    private func checkMark(on: Bool) -> some View {
        ZStack {
            if on {
                Circle().fill(theme.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.accentText)
            } else {
                Circle().strokeBorder(theme.text3, lineWidth: 2)
            }
        }
        .frame(width: 26, height: 26)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 12) {
            Pill(title: "Done", variant: .primary, size: .lg, fullWidth: true) {
                commit()
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

    private func commit() {
        var currentRemovedChats = store.removedChatIds
        for chat in chats {
            if selectedChatIds.contains(chat.id) {
                currentRemovedChats.remove(chat.id)
            } else {
                currentRemovedChats.insert(chat.id)
            }
        }
        var currentRemovedProfiles = store.removedProfileIds
        for profile in profiles {
            if selectedProfileIds.contains(profile.userId) {
                currentRemovedProfiles.remove(profile.userId)
            } else {
                currentRemovedProfiles.insert(profile.userId)
            }
        }
        store.setRemoved(chatIds: currentRemovedChats, profileIds: currentRemovedProfiles)
        onDone()
    }
}
