import SwiftUI

/// A source's default-selection target is separate from its edit/disconnect menu.
struct NSearchSourceRow: View {
    let source: MusicSearchSource
    let isDefault: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    @Environment(\.theme) private var theme

    private var detail: String {
        switch source {
        case .telegram: "Music from your Telegram chats"
        case .bot(let bot): bot.connectionInput
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Image(systemName: source.isTelegram ? "paperplane.fill" : "waveform")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(theme.accentColor)
                        .frame(width: 40, height: 40)
                        .background(theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.label).font(.body.weight(.medium)).foregroundStyle(theme.text).lineLimit(1)
                        Text(detail).font(.caption).foregroundStyle(theme.text2).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(isDefault ? theme.accentColor : theme.text3)
                        .accessibilityHidden(true)
                }
                .padding(.leading, 16).padding(.vertical, 16)
                .padding(.trailing, source.isTelegram ? 16 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(source.label)
            .accessibilityValue(isDefault ? "Default search source" : "")
            .accessibilityHint("Makes this the default for Home search")
            if !source.isTelegram {
                Menu {
                    Button("Edit source", systemImage: "pencil", action: onEdit)
                    Button("Disconnect bot", systemImage: "minus.circle", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold))
                        .foregroundStyle(theme.text2).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.trailing, 8)
                .accessibilityLabel("Options for \(source.label)")
            }
        }
    }
}
