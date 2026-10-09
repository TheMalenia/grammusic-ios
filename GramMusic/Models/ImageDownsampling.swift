import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Decode-at-size helpers for cover art.
///
/// The naive way to make a thumbnail — `UIImage(data:)` then draw into a small rect — fully
/// decodes the source first. Covers here come from the iTunes API at roughly 1000×1000, so each
/// one materialises a ~4 MB bitmap just to produce a few KB of thumbnail; doing that for the
/// eight widget tiles peaked around 32 MB of transient memory on the main actor.
///
/// `CGImageSourceCreateThumbnailAtIndex` decodes straight to the requested size, so the full
/// bitmap never exists. Everything here is pure Core Graphics and safe to call off the main actor.
enum ImageDownsampling {

    /// A JPEG no larger than `maxPixel` on its long edge, decoded without ever materialising the
    /// full-size bitmap. Returns `nil` if `data` isn't a decodable image.
    ///
    /// - Parameters:
    ///   - maxPixel: longest-edge budget in **pixels** (not points).
    ///   - compression: JPEG quality for the re-encode.
    static func jpegThumbnail(from data: Data, maxPixel: CGFloat, compression: CGFloat = 0.65) -> Data? {
        guard let cgImage = downsampledCGImage(from: data, maxPixel: maxPixel) else { return nil }
        return encodeJPEG(cgImage, compression: compression)
    }

    /// A downsampled `CGImage` whose long edge is at most `maxPixel`.
    static func downsampledCGImage(from data: Data, maxPixel: CGFloat) -> CGImage? {
        // `kCGImageSourceShouldCache: false` keeps the decoded source out of the image cache —
        // we only want the thumbnail, not the original.
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard maxPixel > 0,
              let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel.rounded()),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pixel dimensions of an encoded image *without* decoding it — just the header.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Re-encode a `CGImage` as JPEG.
    static func encodeJPEG(_ image: CGImage, compression: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compression]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Shrink an oversized cover before it is held in memory or written to disk. Returns the
    /// original bytes when they are already within budget (or can't be read), so callers can use
    /// this unconditionally.
    static func capped(_ data: Data, maxPixel: CGFloat, compression: CGFloat = 0.82) -> Data {
        guard let size = pixelSize(of: data), max(size.width, size.height) > maxPixel else {
            return data
        }
        guard let shrunk = jpegThumbnail(from: data, maxPixel: maxPixel, compression: compression),
              shrunk.count < data.count
        else { return data }
        return shrunk
    }
}
