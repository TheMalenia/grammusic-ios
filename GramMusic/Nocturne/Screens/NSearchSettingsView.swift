import SwiftUI

/// Search sources are selected here; connecting a bot has its own focused sheet.
struct NSearchSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TelegramService.self) private var telegram
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var showConnect = false
    @State private var editingBot: MusicSearchBot?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Telegram inline bots can return music files. We use those files as search results. Choose where Home search starts below.")
                        .font(.subheadline).foregroundStyle(theme.text2)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your sources").font(.headline).foregroundStyle(theme.text)
                        VStack(spacing: 0) {
                            ForEach(Array(telegram.searchSources.sources.enumerated()), id: \.element.id) { index, source in
                                NSearchSourceRow(source: source,
                                    isDefault: source.id == telegram.searchSources.defaultSourceID,
                                    onSelect: { telegram.searchSources.setDefault(source) },
                                    onEdit: { if case .bot(let bot) = source { editingBot = bot } },
                                    onRemove: { if case .bot(let bot) = source { telegram.searchSources.remove(bot) } })
                                if index < telegram.searchSources.sources.count - 1 {
                                    Divider().overlay(theme.hairline).padding(.leading, 72)
                                }
                            }
                        }
                        .nocturneGlassCard(theme)
                        Text("Tap a source to make it your default. You can switch tabs while searching.")
                            .font(.caption).foregroundStyle(theme.text2).padding(.horizontal, 4)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Save songs played from search", isOn: $settings.saveSearchResults)
                            .font(.body)
                            .foregroundStyle(theme.text)
                            .tint(theme.accentColor)
                            .padding(16)
                            .nocturneGlassCard(theme)
                        Text("Songs you listen to from search are saved to the Search playlist in your Library. Turning this off keeps songs already saved.")
                            .font(.caption)
                            .foregroundStyle(theme.text2)
                            .padding(.horizontal, 4)
                    }

                    Pill(title: "Connect a bot", systemImage: "plus", variant: .light, size: .lg,
                         fullWidth: true) { showConnect = true }
                    Text("You can connect your own Telegram inline music bot to add it as a search source.")
                        .font(.subheadline).foregroundStyle(theme.text2)
                        .padding(.horizontal, 4)
                }
                .padding(20)
            }
            .background(ScreenBackground())
            .navigationTitle("Search settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: settings.saveSearchResults, initial: true) { _, enabled in
                if enabled { PlaylistService(context: context).searchPlaylist() }
            }
            .sensoryFeedback(.selection, trigger: telegram.searchSources.defaultSourceID)
        }
        .sheet(isPresented: $showConnect) { NConnectSearchBotView() }
        .sheet(item: $editingBot) { NEditSearchBotView(bot: $0) }
    }
}
