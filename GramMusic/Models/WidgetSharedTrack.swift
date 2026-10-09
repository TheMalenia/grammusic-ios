import Foundation

public struct WidgetSharedTrack: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let artworkData: Data?

    public init(id: String, title: String, artist: String, artworkData: Data? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkData = artworkData
    }

    public var displayTitle: String {
        title.isEmpty ? "Unknown Track" : title
    }

    public var displayArtist: String {
        artist.isEmpty ? "Unknown Artist" : artist
    }
}
