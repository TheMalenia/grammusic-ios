import SwiftUI

/// A dedicated connection flow keeps the source list clear and the primary action in reach.
struct NConnectSearchBotView: View {
    @Environment(TelegramService.self) private var telegram
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var username = ""
    @State private var displayName = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var connectionTask: Task<Void, Never>?
    @FocusState private var focus: Field?
    private enum Field { case username, name }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Add a Telegram bot's music search to your app.")
                        .font(.subheadline).foregroundStyle(theme.text2)
                    NSearchSourceField(title: "Bot username", hint: "If the bot needs a prefix, enter it after the username: @musicbot music.",
                                       isFocused: focus == .username) {
                        TextField("Enter bot username", text: $username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .username).submitLabel(.next)
                            .onSubmit { focus = .name }
                            .accessibilityLabel("Bot username and optional query prefix")
                    }
                    NSearchSourceField(title: "Display name", optional: true,
                                       hint: "Leave empty to use the bot's username.", isFocused: focus == .name) {
                        TextField("Name in search", text: $displayName)
                            .focused($focus, equals: .name).submitLabel(.done).onSubmit(connect)
                            .accessibilityLabel("Display name, optional")
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(theme.text)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel("Couldn't connect. \(error)")
                    }
                    Label("Listening here doesn't send a Telegram message.", systemImage: "lock")
                        .font(.caption).foregroundStyle(theme.text2)
                }
                .padding(20).disabled(connecting)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ScreenBackground())
            .navigationTitle("Connect bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark", action: cancel).labelStyle(.iconOnly) } }
            .safeAreaInset(edge: .bottom) {
                Pill(title: connecting ? "Connecting…" : "Connect bot", systemImage: "plus", size: .lg,
                     fullWidth: true, isLoading: connecting, action: connect)
                    .disabled(connecting || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(!connecting && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(NBarSurface().ignoresSafeArea(edges: .bottom))
            }
        }
        .interactiveDismissDisabled(connecting)
        .onDisappear { connectionTask?.cancel() }
    }

    private func connect() {
        guard !connecting, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        focus = nil
        connecting = true
        error = nil
        let input = username
        let name = displayName
        connectionTask = Task { @MainActor in
            defer { connecting = false }
            do {
                try await telegram.connectSearchBot(input, displayName: name)
                dismiss()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func cancel() { connectionTask?.cancel(); dismiss() }
}
