import SwiftUI
import WidgetKit

// MARK: - Timeline Entry

struct RecentlyPlayedEntry: TimelineEntry {
    let date: Date
    let tracks: [WidgetSharedTrack]
}

// MARK: - Timeline Provider

struct RecentlyPlayedProvider: TimelineProvider {
    private func sampleEntry() -> RecentlyPlayedEntry {
        RecentlyPlayedEntry(date: Date(), tracks: [
            WidgetSharedTrack(id: "1", title: "Blinding Lights", artist: "The Weeknd"),
            WidgetSharedTrack(id: "2", title: "Starboy", artist: "The Weeknd"),
            WidgetSharedTrack(id: "3", title: "Shape of You", artist: "Ed Sheeran"),
            WidgetSharedTrack(id: "4", title: "Levitating", artist: "Dua Lipa"),
            WidgetSharedTrack(id: "5", title: "Save Your Tears", artist: "The Weeknd"),
            WidgetSharedTrack(id: "6", title: "Stay", artist: "The Kid LAROI"),
            WidgetSharedTrack(id: "7", title: "As It Was", artist: "Harry Styles"),
            WidgetSharedTrack(id: "8", title: "Midnight City", artist: "M83")
        ])
    }

    func placeholder(in context: Context) -> RecentlyPlayedEntry {
        sampleEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentlyPlayedEntry) -> Void) {
        if context.isPreview {
            let entry = fetchEntry()
            completion(entry.tracks.isEmpty ? sampleEntry() : entry)
        } else {
            completion(fetchEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentlyPlayedEntry>) -> Void) {
        let entry = fetchEntry()
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))
        completion(timeline)
    }

    private func fetchEntry() -> RecentlyPlayedEntry {
        let tracks = WidgetSharedStore.loadTracks()
        return RecentlyPlayedEntry(date: Date(), tracks: tracks)
    }
}

// MARK: - Widget View (Medium Size Only)

struct RecentlyPlayedWidgetView: View {
    var entry: RecentlyPlayedProvider.Entry
    @Environment(\.colorScheme) var colorScheme

    private let telegramBlue = Color(red: 95/255, green: 176/255, blue: 236/255) // #5FB0EC

    var body: some View {
        mediumGrid(tracks: Array(entry.tracks.prefix(8)))
    }

    // MARK: - Medium (2x4 = 8 Rectangles)

    @ViewBuilder
    private func mediumGrid(tracks: [WidgetSharedTrack]) -> some View {
        if tracks.isEmpty {
            emptyState
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(0..<8, id: \.self) { index in
                    if index < tracks.count {
                        coverTile(track: tracks[index])
                    } else {
                        placeholderCoverTile
                    }
                }
            }
            .containerBackground(for: .widget) {
                widgetBackground
            }
        }
    }

    // MARK: - Cover Rectangle Tile (No Text, Clean Covers)

    private func coverTile(track: WidgetSharedTrack) -> some View {
        Link(destination: URL(string: "grammusic://play?id=\(track.id)")!) {
            ZStack {
                if let image = WidgetSharedStore.loadCoverImage(for: track.id) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(1.0, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if let data = track.artworkData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(1.0, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [gradientColor(for: track.title, shift: 0),
                                     gradientColor(for: track.title, shift: 1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .aspectRatio(1.0, contentMode: .fit)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 3, y: 1.5)
        }
    }

    // MARK: - Placeholder Tile

    private var placeholderCoverTile: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04))
            .aspectRatio(1.0, contentMode: .fit)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 28))
                .foregroundStyle(telegramBlue)
            Text("Recently Played")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(colorScheme == .dark ? .white : .black)
            Text("Play tracks in GramMusic to see them here.")
                .font(.system(size: 11))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .containerBackground(for: .widget) {
            widgetBackground
        }
    }

    // MARK: - Dynamic Theme Background (Dark & Light)

    private var widgetBackground: some View {
        ZStack {
            if colorScheme == .dark {
                Color(red: 0.06, green: 0.07, blue: 0.09)
                LinearGradient(
                    colors: [
                        telegramBlue.opacity(0.12),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                Color(red: 0.94, green: 0.94, blue: 0.96)
                LinearGradient(
                    colors: [
                        telegramBlue.opacity(0.08),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    // MARK: - Artwork Fallback Colors

    private func gradientColor(for title: String, shift: Int) -> Color {
        let hash = abs(title.hashValue)
        let palettes: [[Color]] = [
            [Color(hex: 0x3FA0F2), Color(hex: 0x1E56A0)], // Telegram Blue
            [Color(hex: 0x5FB0EC), Color(hex: 0x2A628F)], // Logo Blue
            [Color(hex: 0x6A4FE6), Color(hex: 0x2E1C7A)], // Indigo
            [Color(hex: 0x22B8D6), Color(hex: 0x0E5466)], // Cyan
            [Color(hex: 0x9A45E0), Color(hex: 0x4A1875)], // Violet
            [Color(hex: 0x2BC07E), Color(hex: 0x135E3B)]  // Mint Green
        ]
        let palette = palettes[hash % palettes.count]
        return palette[shift % palette.count]
    }
}

// MARK: - Color Extension

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Widget Configuration

struct RecentlyPlayedWidget: Widget {
    let kind: String = "RecentlyPlayedWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentlyPlayedProvider()) { entry in
            RecentlyPlayedWidgetView(entry: entry)
        }
        .configurationDisplayName("Recently Played")
        .description("Your 8 recently played music covers. Tap any to play.")
        .supportedFamilies([.systemMedium])
    }
}
