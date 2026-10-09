import SwiftUI

/// Persistent labels and roomy input surfaces for connecting and editing search sources.
struct NSearchSourceField<Content: View>: View {
    let title: String
    var optional = false
    var hint: String? = nil
    var isFocused = false
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
                Spacer()
                if optional { Text("Optional").font(.caption).foregroundStyle(theme.text2) }
            }
            content
                .font(.body).foregroundStyle(theme.text)
                .padding(16).frame(minHeight: 52)
                .background(theme.elev, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isFocused ? theme.accentColor.opacity(0.7) : theme.hairline,
                                      lineWidth: isFocused ? 1 : 0.5)
                }
            if let hint { Text(hint).font(.caption).foregroundStyle(theme.text2).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
