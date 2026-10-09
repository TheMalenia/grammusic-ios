import Foundation
import UIKit

public enum WidgetSharedStore {
    public static let appGroupId = "group.com.grammusic.app"
    private static let metadataFileName = "widget_recent_tracks.json"
    private static let coversDirectoryName = "WidgetCovers"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    public static var coversDirectoryURL: URL? {
        guard let container = containerURL else { return nil }
        let dir = container.appendingPathComponent(coversDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func coverImageURL(for trackId: String) -> URL? {
        coversDirectoryURL?.appendingPathComponent("\(trackId).jpg")
    }

    public static func saveTracks(_ tracks: [WidgetSharedTrack], thumbnails: [String: Data]) {
        // 1. Save thumbnail image files to shared directory (if App Group disk container is available)
        if let coversDir = coversDirectoryURL {
            for (trackId, data) in thumbnails {
                let fileURL = coversDir.appendingPathComponent("\(trackId).jpg")
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        // 2. Save metadata JSON to shared container disk (if available)
        if let container = containerURL {
            let metaURL = container.appendingPathComponent(metadataFileName)
            if let data = try? JSONEncoder().encode(tracks) {
                try? data.write(to: metaURL, options: .atomic)
            }
        }

        // 3. Always save to App Group and Standard UserDefaults
        if let data = try? JSONEncoder().encode(tracks) {
            UserDefaults(suiteName: appGroupId)?.set(data, forKey: "n_widget_recent_tracks")
            UserDefaults.standard.set(data, forKey: "n_widget_recent_tracks")
        }
    }

    public static func loadTracks() -> [WidgetSharedTrack] {
        // 1. Try reading metadata JSON from shared container disk
        if let container = containerURL {
            let metaURL = container.appendingPathComponent(metadataFileName)
            if let data = try? Data(contentsOf: metaURL),
               let decoded = try? JSONDecoder().decode([WidgetSharedTrack].self, from: data),
               !decoded.isEmpty {
                return decoded
            }
        }

        // 2. Fallback to App Group UserDefaults
        if let defaults = UserDefaults(suiteName: appGroupId),
           let data = defaults.data(forKey: "n_widget_recent_tracks"),
           let decoded = try? JSONDecoder().decode([WidgetSharedTrack].self, from: data),
           !decoded.isEmpty {
            return decoded
        }

        // 3. Fallback to standard defaults
        if let data = UserDefaults.standard.data(forKey: "n_widget_recent_tracks"),
           let decoded = try? JSONDecoder().decode([WidgetSharedTrack].self, from: data),
           !decoded.isEmpty {
            return decoded
        }

        return []
    }

    public static func loadCoverImage(for trackId: String) -> UIImage? {
        guard let url = coverImageURL(for: trackId),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    public static func clear() {
        if let coversDir = coversDirectoryURL {
            try? FileManager.default.removeItem(at: coversDir)
        }
        if let container = containerURL {
            let metaURL = container.appendingPathComponent(metadataFileName)
            try? FileManager.default.removeItem(at: metaURL)
        }
        UserDefaults(suiteName: appGroupId)?.removeObject(forKey: "n_widget_recent_tracks")
        UserDefaults(suiteName: appGroupId)?.removeObject(forKey: "recentlyPlayed")
        UserDefaults.standard.removeObject(forKey: "n_widget_recent_tracks")
    }
}
