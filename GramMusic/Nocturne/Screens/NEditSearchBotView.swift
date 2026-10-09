import SwiftUI

/// Edit presentation and query arguments without changing the connected Telegram identity.
struct NEditSearchBotView: View {
    let bot: MusicSearchBot
    @Environment(TelegramService.self) private var telegram
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var displayName: String
    @State private var queryPrefix: String
    @FocusState private var focus: Field?
    private enum Field { case name, prefix }

    init(bot: MusicSearchBot) {
        self.bot = bot
        _displayName = State(initialValue: bot.displayName ?? "")
        _queryPrefix = State(initialValue: bot.queryPrefix ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("@" + bot.username, systemImage: "waveform")
                        .font(.headline).foregroundStyle(theme.text)
                    NSearchSourceField(title: "Display name", optional: true,
                                       hint: "Leave empty to use the bot's username.", isFocused: focus == .name) {
                        TextField("Name in search", text: $displayName)
                            .focused($focus, equals: .name).submitLabel(.next)
                            .onSubmit { focus = .prefix }
                            .accessibilityLabel("Display name, optional")
                    }
                    NSearchSourceField(title: "Query prefix", optional: true,
                                       hint: "For a bot that needs “music”, enter music here. A search for Halo will send “music Halo”.",
                                       isFocused: focus == .prefix) {
                        TextField("e.g. music", text: $queryPrefix)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .prefix).submitLabel(.done).onSubmit(save)
                            .accessibilityLabel("Query prefix, optional")
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ScreenBackground())
            .navigationTitle("Edit source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) } }
            .safeAreaInset(edge: .bottom) {
                Pill(title: "Save changes", systemImage: "checkmark", size: .lg, fullWidth: true, action: save)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(NBarSurface().ignoresSafeArea(edges: .bottom))
            }
        }
    }

    private func save() {
        telegram.searchSources.update(bot, displayName: displayName, queryPrefix: queryPrefix)
        dismiss()
    }
}
