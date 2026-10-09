import SwiftUI

/// Add-artist flow reached from the Library ＋ menu. Searches the user's Telegram audio for
/// performers (reusing `searchAudio`) and, when the query is empty, suggests artists found in
/// the user's own songs that they don't already follow. Following is inline (multi-select);
/// the sheet stays open so several artists can be followed in one pass.
struct NAddArtistSheet: View {
    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    @Environment(\.dismiss) private var dismiss

    /// Pre-computed unfollowed performers from the user's library (passed in by the caller so
    /// playlist tracks can contribute alongside recently-played).
    let suggestions: [String]

    @State private var query = ""
    @State private var results: [String] = []
    @State private var searching = false

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                searchField
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if trimmed.isEmpty {
                            section("Suggested for you", names: suggestions,
                                    empty: "Play a few songs and we'll suggest artists to follow.")
                        } else if searching && results.isEmpty {
                            ProgressView().tint(theme.accentColor).padding(.top, 40)
                        } else {
                            section("Results", names: results,
                                    empty: "No artists found for “\(trimmed)”.")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .background(ScreenBackground())
            .navigationTitle("Add Artist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(theme.accentColor)
                }
            }
            .task(id: trimmed) { await search() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: SearchChrome.iconSize, weight: .medium)).foregroundStyle(theme.text3)
            TextField("Search artists", text: $query)
                .font(.system(size: SearchChrome.textSize))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .foregroundStyle(theme.text)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.text3)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).frame(height: SearchChrome.height)
        .nGlass(SearchChrome.shape, theme: theme)
        .padding(.horizontal, 16).padding(.top, 8)
    }

    @ViewBuilder private func section(_ title: String, names: [String], empty: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text2)
            Spacer()
        }
        .padding(.horizontal, 4).padding(.top, 6).padding(.bottom, 2)

        if names.isEmpty {
            Text(empty).font(.system(size: 14)).foregroundStyle(theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4).padding(.top, 24)
        } else {
            ForEach(names, id: \.self) { name in row(name) }
        }
    }

    private func row(_ name: String) -> some View {
        let following = telegram.isFollowing(artist: name)
        return HStack(spacing: 12) {
            NArtistAvatar(name: name, size: 48)
            Text(name).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
            Spacer(minLength: 8)
            Pill(title: following ? "Following" : "Follow",
                 systemImage: following ? "checkmark" : "plus",
                 variant: following ? .ghost : .primary, size: .sm) {
                withAnimation { telegram.toggleFollow(artist: name) }
            }
        }
        .padding(.vertical, 6)
    }

    private func search() async {
        guard !trimmed.isEmpty else { results = []; searching = false; return }
        searching = true
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        let term = trimmed
        let tracks = (try? await telegram.searchAudio(term)) ?? []
        if Task.isCancelled || term != trimmed { return }
        // One distinct performer per artist, best match first — same folding as every other
        // search surface, so a Persian or accented spelling isn't treated as a different artist.
        results = AudioSearch.artists(in: tracks, query: term, limit: 20)
        searching = false
    }
}
