import SwiftUI
import SwiftData

/// Drives one assistant conversation: user text in, a `Selection` preview out.
///
/// The **Composer** is injected, so this controller is identical whether the request was parsed
/// on-device by rules, by a local model, or by a provider behind a proxy. Swapping providers
/// never touches this file.
@MainActor
@Observable
final class AssistantController {

    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        /// Present when the reply produced something buildable.
        var selection: RecipeSelector.Selection?
    }

    private(set) var messages: [Message] = []
    private(set) var isThinking = false

    private let composer: PlaylistComposer
    private let hydrator: SnapshotHydrator
    private var snapshot: LibrarySnapshot

    init(composer: PlaylistComposer = HeuristicComposer(),
         hydrator: SnapshotHydrator,
         snapshot: LibrarySnapshot) {
        self.composer = composer
        self.hydrator = hydrator
        self.snapshot = snapshot
    }

    func refresh(snapshot: LibrarySnapshot) { self.snapshot = snapshot }

    /// Tappable openers, built from names the user actually has. A blank box is where a small
    /// model — and a rule-based parser even more so — performs worst; concrete starters both
    /// raise the hit rate and teach the format.
    var starters: [String] {
        var out: [String] = []
        if let artist = snapshot.artists.first { out.append("Chill \(artist)") }
        if let chat = snapshot.chats.first?.title { out.append("20 tracks from \(chat)") }
        if !snapshot.favorites.isEmpty { out.append("Something from my favourites") }
        if let artist = snapshot.artists.dropFirst().first { out.append("Most played \(artist)") }
        return out
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }

        messages.append(Message(role: .user, text: trimmed))
        isThinking = true
        defer { isThinking = false }

        do {
            let reply = try await composer.compose(trimmed, roster: snapshot.roster.capped())
            guard let recipe = reply.recipe else {
                messages.append(Message(role: .assistant, text: reply.reply))
                return
            }

            // Fetch what the request named but the caches don't hold — an unopened chat, an
            // unfollowed artist — then select from the enriched snapshot. Only what was named is
            // fetched, so this stays cheap. The result is kept so a follow-up request reuses it.
            snapshot = await hydrator.hydrate(recipe, into: snapshot)
            let selection = RecipeSelector.select(recipe, from: snapshot)
            messages.append(Message(role: .assistant,
                                    text: narrate(reply: reply, selection: selection),
                                    selection: selection.isEmpty ? nil : selection))
        } catch let error as ComposerError {
            // A transient failure is not the user's fault and is worth retrying; an unusable
            // request is. Same split as `TelegramError`.
            switch error {
            case .transient:
                messages.append(Message(role: .assistant,
                                        text: "I couldn't reach the model just then — try again."))
            case .unusable(let why):
                messages.append(Message(role: .assistant, text: why))
            }
        } catch {
            messages.append(Message(role: .assistant, text: "Something went wrong building that."))
        }
    }

    /// What the user is told. Unmatched names are always surfaced — silently dropping a name
    /// someone typed is how an assistant earns distrust.
    private func narrate(reply: ComposerReply, selection: RecipeSelector.Selection) -> String {
        let missed = selection.unmatchedArtists + selection.unmatchedChats

        if selection.missedEverything {
            return "I couldn't find \(list(missed)) in your library."
        }
        var text = "\(selection.name) — \(selection.tracks.count) "
            + (selection.tracks.count == 1 ? "track" : "tracks") + "."
        if !missed.isEmpty {
            text += " I couldn't find \(list(missed)), so it's not in there."
        }
        return text
    }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: "“\(items[0])”"
        default: items.map { "“\($0)”" }.dropLast().joined(separator: ", ")
            + " or " + "“\(items.last ?? "")”"
        }
    }
}

/// The AI tab: describe a playlist, see exactly what it would contain, then keep it.
///
/// The preview-then-confirm shape is deliberate. Creating a playlist the moment a sentence is
/// parsed would mean a misread request silently litters the user's Library; showing the real
/// tracks first makes a wrong answer cost one glance instead of a cleanup.
struct NAIView: View {
    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    @Environment(ImportStore.self) private var importStore
    @Environment(\.modelContext) private var context
    @Query private var playlists: [Playlist]

    @State private var controller: AssistantController?
    @State private var snapshot = LibrarySnapshot()
    @State private var draft = ""
    @State private var created: Set<UUID> = []
    @FocusState private var focused: Bool

    private var service: PlaylistService { PlaylistService(context: context) }

    var body: some View {
        NavigationStack {
            Group {
                if snapshot.hasEnoughToCompose {
                    conversation
                } else {
                    emptyLibrary
                }
            }
            .background(ScreenBackground())
            .navigationTitle("AI")
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear(perform: refresh)
        // The library grows while the tab is alive (a chat gets imported, an artist followed), and
        // a tab — unlike a sheet — is never re-created. Re-read on every appearance.
        .onChange(of: telegram.chats.count) { refresh() }
        .onChange(of: playlists.count) { refresh() }
    }

    private func refresh() {
        snapshot = .live(telegram: telegram,
                         playlists: playlists,
                         importedChatIds: importStore.isChatImported)
        if let controller {
            controller.refresh(snapshot: snapshot)
        } else {
            controller = AssistantController(hydrator: SnapshotHydrator(telegram: telegram),
                                             snapshot: snapshot)
        }
    }

    // MARK: Conversation

    @ViewBuilder
    private var conversation: some View {
        if let controller {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if controller.messages.isEmpty { intro(controller) }
                            ForEach(controller.messages) { bubble($0) }
                            if controller.isThinking {
                                ProgressView().tint(theme.accentColor).padding(.leading, 4)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: controller.messages.count) {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                inputBar(controller)
            }
        }
    }

    private func intro(_ controller: AssistantController) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe a playlist and I'll build it from your own library.")
                .font(.system(size: 15)).foregroundStyle(theme.text2)

            ForEach(controller.starters, id: \.self) { starter in
                Button {
                    Task { await controller.send(starter) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: 13))
                        Text(starter).font(.system(size: 14, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.elev))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func bubble(_ message: AssistantController.Message) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(theme.accentColor))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.text)
                if let selection = message.selection {
                    preview(selection, messageId: message.id)
                }
            }
        }
    }

    // MARK: Preview + confirm

    private func preview(_ selection: RecipeSelector.Selection, messageId: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(selection.tracks.prefix(6).enumerated()), id: \.element.id) { index, track in
                TrackRow(title: track.displayTitle,
                         subtitle: track.displaySubtitle,
                         seed: track.remoteUniqueId,
                         artworkData: track.artworkData,
                         track: track,
                         index: index + 1,
                         duration: track.formattedDuration)
            }

            if selection.tracks.count > 6 {
                Text("+ \(selection.tracks.count - 6) more")
                    .font(.system(size: 13)).foregroundStyle(theme.text3)
                    .padding(.horizontal, 12).padding(.top, 6)
            }

            Divider().overlay(theme.hairline).padding(.vertical, 10)

            if created.contains(messageId) {
                Label("Added to your Library", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            } else {
                Button {
                    create(selection, messageId: messageId)
                } label: {
                    Text("Create “\(selection.name)”")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.accentColor))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.elev))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(theme.hairline, lineWidth: 0.5))
    }

    /// Writes the playlist only on an explicit tap, and marks the message done so a second tap
    /// can't create a duplicate.
    private func create(_ selection: RecipeSelector.Selection, messageId: UUID) {
        let playlist = service.create(name: selection.name)
        for track in selection.tracks { service.add(track, to: playlist) }
        created.insert(messageId)
    }

    // MARK: Input

    private func inputBar(_ controller: AssistantController) -> some View {
        HStack(spacing: 8) {
            TextField("Describe a playlist…", text: $draft, axis: .vertical)
                .font(.system(size: SearchChrome.textSize))
                .lineLimit(1...4)
                .foregroundStyle(theme.text)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? theme.text3 : theme.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || controller.isThinking)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .nGlass(SearchChrome.shape, theme: theme)
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func submit() {
        guard let controller else { return }
        let text = draft
        draft = ""
        Task { await controller.send(text) }
    }

    // MARK: Empty state

    private var emptyLibrary: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 34)).foregroundStyle(theme.text3)
            Text("Nothing to build from yet")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
            Text("Import a chat or follow an artist, and I can put playlists together from them.")
                .font(.system(size: 14)).foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
