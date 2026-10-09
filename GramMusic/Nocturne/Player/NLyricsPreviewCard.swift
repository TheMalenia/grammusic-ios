import SwiftUI

/// First discovery card below the player; timing updates are confined to the lyric text.
struct NLyricsPreviewCard: View {
    let lyrics: Lyrics?
    let isLoading: Bool
    let tint: Color
    let showLyrics: () -> Void

    @ScaledMetric(relativeTo: .title2) private var previewHeight = 200.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lyrics preview")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Group {
                if let lyrics {
                    NLyricsText(lyrics: lyrics, isPreview: true)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if isLoading {
                            ProgressView().tint(.white)
                            Text("Checking for lyrics…")
                        } else {
                            Image(systemName: "quote.bubble")
                                .font(.title2)
                                .accessibilityHidden(true)
                            Text("No lyrics found")
                        }
                    }
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            // Clip at the fixed viewport, rather than at the text's intrinsic height.
            // Long embedded lines must never draw over the card header or action.
            .frame(height: lyrics == nil ? 72 : previewHeight, alignment: .top)
            .clipped()
            .mask {
                if lyrics != nil {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                } else {
                    Rectangle()
                }
            }

            if lyrics != nil {
                Button(action: showLyrics) {
                    HStack(spacing: 8) {
                        Text("Show lyrics")
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(.black.opacity(0.25), in: Capsule())
                }
                .buttonStyle(NPressable(scale: 0.97))
                .accessibilityHint("Opens the full lyrics")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(tint)
                .overlay(.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
