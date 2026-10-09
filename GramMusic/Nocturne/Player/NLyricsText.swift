import SwiftUI

/// Shared lyrics presentation for the compact card and expanded sheet.
struct NLyricsText: View {
    let lyrics: Lyrics
    let isPreview: Bool

    var body: some View {
        Group {
            if lyrics.isSynced {
                NSyncedLyricsList(lines: lyrics.syncedLines, isPreview: isPreview)
            } else if isPreview {
                plainLines
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
            } else {
                ScrollView {
                    plainLines
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .environment(\.layoutDirection, lyrics.isRTL ? .rightToLeft : .leftToRight)
    }

    private var plainLines: some View {
        let lines = isPreview ? Array(lyrics.displayLines.prefix(4)) : lyrics.displayLines
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.title2.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
