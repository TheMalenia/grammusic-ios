import SwiftUI
import PhotosUI

/// Sheet for editing an existing playlist's name and cover image. Same visual language as
/// `NNewPlaylistSheet` — centered cover tile with camera badge, name field, Cancel / Save.
struct NEditPlaylistSheet: View {
    @Bindable var playlist: Playlist

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name: String = ""
    @State private var selectedItem: PhotosPickerItem?
    @State private var coverData: Data?
    /// Tracks whether the user explicitly removed the cover (vs. never having one).
    @State private var coverRemoved = false
    @FocusState private var focused: Bool

    private var service: PlaylistService { PlaylistService(context: context) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The cover bytes to display: user-picked first, then the existing cover (unless removed).
    ///
    /// `Data` rather than `UIImage` because this is read inside `PhotosPicker`'s label closure,
    /// which is `@Sendable` — so whatever crosses into it must be Sendable, and `UIImage` is not.
    private var displayCoverData: Data? {
        if let coverData { return coverData }
        if coverRemoved { return nil }
        return playlist.coverImageData
    }

    private var displayImage: UIImage? { displayCoverData.flatMap(UIImage.init(data:)) }

    var body: some View {
        // Named distinctly: a local called `coverData` would shadow the `@State` of that name and
        // silently turn the picker's write into an assignment to a `let`.
        let pickedCover = displayCoverData
        let seed = name.isEmpty ? playlist.name : name
        return NavigationStack {
            VStack(spacing: 28) {
                // Cover tile — tappable to pick a new photo.
                ZStack(alignment: .bottomTrailing) {
                    // The label reads only Sendable locals; `PhotosPicker`'s label closure is
                    // `@Sendable`, so capturing the view itself is what strict concurrency flags.
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        NCoverPickerTile(coverData: pickedCover, fallbackSeed: seed)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 24)
                .onChange(of: selectedItem) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self) {
                            if let ui = UIImage(data: data),
                               let jpeg = ui.jpegData(compressionQuality: 0.82) {
                                coverData = jpeg
                            } else {
                                coverData = data
                            }
                            coverRemoved = false
                        }
                    }
                }

                // Remove cover button — only when there's a cover to remove.
                if displayImage != nil {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            coverData = nil
                            coverRemoved = true
                            selectedItem = nil
                        }
                    } label: {
                        Label("Remove Cover", systemImage: "trash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }

                TextField("Playlist name", text: $name)
                    .font(.title2.bold())
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)

                Spacer()
            }
            .padding(24)
            .background(ScreenBackground())
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold).disabled(trimmed.isEmpty)
                }
            }
            .onAppear {
                name = playlist.name
                focused = true
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        if trimmed != playlist.name { service.rename(playlist, to: trimmed) }

        // Determine final cover data.
        if let coverData {
            service.setCoverImage(playlist, data: coverData)
        } else if coverRemoved {
            service.setCoverImage(playlist, data: nil)
        }
        dismiss()
    }
}
