import SwiftUI

/// Compact bulk actions with a full touch target inside every button label.
struct NTrackSelectionToolbar: View {
    @Environment(\.theme) private var theme
    let selection: NTrackSelection
    let isWorking: Bool
    let hasSelection: Bool
    let destructiveTitle: String?
    var destructiveIcon = "trash"
    let onSelectAll: () -> Void
    let onAdd: () -> Void
    let onDestructive: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if isWorking {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Updating selected songs")
            } else {
                Text(selection.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            action("Select all", icon: "checkmark.circle", perform: onSelectAll)
                .disabled(isWorking)
                .accessibilityIdentifier("selection.all")
            action("Add to playlist", icon: "text.badge.plus", perform: onAdd)
                .disabled(isWorking || !hasSelection)
                .accessibilityIdentifier("selection.add")
            if let destructiveTitle {
                action(destructiveTitle,
                       icon: destructiveIcon,
                       role: destructiveIcon == "eye" ? nil : .destructive, perform: onDestructive)
                    .disabled(isWorking || !hasSelection)
                    .accessibilityIdentifier("selection.remove")
            }
            action("Close selection", icon: "xmark", perform: onClose)
                .accessibilityIdentifier("selection.close")
        }
        .buttonStyle(.plain)
    }

    private func action(_ title: String, icon: String, role: ButtonRole? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .foregroundStyle(role == .destructive ? Color.red : (icon == "xmark" ? theme.text2 : theme.accentColor))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
}
