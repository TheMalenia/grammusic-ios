import SwiftUI
import UIKit
import AVFoundation
import CoreImage

extension String {
    var isFarsi: Bool {
        range(of: "\\p{Arabic}", options: .regularExpression) != nil
    }
}

extension View {
    @ViewBuilder
    func farsiSupport(text: String, size: CGFloat, weight: Font.Weight) -> some View {
        self.font(.system(size: size, weight: weight))
            .environment(\.layoutDirection, text.isFarsi ? .rightToLeft : .leftToRight)
    }
}

/// The platforms we can share to.
enum ShareTarget {
    case instagram
    case system
}

enum ShareCardMode {
    case normal
    case lyrics
}

/// Renders a beautiful share card for Instagram Stories or Twitter.
struct ShareCard: View {
    let track: AudioTrack
    let artworkImage: UIImage?
    let lyrics: [LyricLine]?
    let mode: ShareCardMode
    let backgroundColor: Color // The background color of the card (used in lyrics mode)

    var body: some View {
        ZStack {
            // Background
            backgroundColor
            
            // Content
            if mode == .lyrics {
                // Lyrics mode layout
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    // Header: Small cover + track details
                    HStack(spacing: 24) {
                        if let uiImage = artworkImage {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                        } else {
                            SeededArtwork(seed: track.remoteUniqueId, style: .gradient, kind: .track, size: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text(track.displayTitle)
                                .farsiSupport(text: track.displayTitle, size: 36, weight: .bold)
                                .foregroundStyle(backgroundColor.isDark ? .white : .black)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(track.displaySubtitle)
                                .farsiSupport(text: track.displaySubtitle, size: 28, weight: .medium)
                                .foregroundStyle(backgroundColor.isDark ? Color.white.opacity(0.7) : Color.black.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 64)
                    
                    // Lyrics (max 4 lines)
                    if let lyrics = lyrics, !lyrics.isEmpty {
                        let selectedLyrics = Array(lyrics.prefix(4))
                        let combinedLyrics = selectedLyrics.map { $0.text }.joined(separator: "\n")
                        
                        Text(combinedLyrics)
                            .farsiSupport(text: combinedLyrics, size: 160, weight: .bold)
                            .minimumScaleFactor(0.25)
                            .lineLimit(selectedLyrics.count * 2)
                            .foregroundStyle(backgroundColor.isDark ? .white : .black)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 64)
                    }
                    Spacer()
                    // Branding
                    HStack(spacing: 16) {
                        Image(systemName: "music.note")
                        Text("GramMusic")
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(backgroundColor.isDark ? .white : .black)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(100)
                .frame(width: 1080, height: 1920)
                .environment(\.layoutDirection, ((lyrics?.contains(where: { $0.text.isFarsi }) == true) || track.displayTitle.isFarsi) ? .rightToLeft : .leftToRight)
            } else {
                // Standard layout without lyrics
                VStack(spacing: 64) {
                    Spacer()
                    // Artwork
                    if let uiImage = artworkImage {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 720, height: 720)
                            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                            .shadow(color: .black.opacity(0.2), radius: 32, y: 16)
                    } else {
                        SeededArtwork(seed: track.remoteUniqueId, style: .gradient, kind: .track, size: 720)
                            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                            .shadow(color: .black.opacity(0.2), radius: 32, y: 16)
                    }
                    
                    // Text
                    VStack(spacing: 24) {
                        Text(track.displayTitle)
                            .farsiSupport(text: track.displayTitle, size: 64, weight: .bold)
                            .foregroundStyle(backgroundColor.isDark ? .white : .black)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Text(track.displaySubtitle)
                            .farsiSupport(text: track.displaySubtitle, size: 40, weight: .medium)
                            .foregroundStyle(backgroundColor.isDark ? Color.white.opacity(0.7) : Color.black.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    
                    // Branding
                    HStack(spacing: 16) {
                        Image(systemName: "music.note")
                        Text("GramMusic")
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(backgroundColor.isDark ? .white : .black)
                    .padding(.top, 24)
                }
                .padding(72)
                .frame(width: 1080, height: 1920)
                .environment(\.layoutDirection, track.displayTitle.isFarsi ? .rightToLeft : .leftToRight)
            }
        }
    }
}

extension Color {
    var isDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: nil)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance < 0.5
    }
}

@MainActor
final class ShareService {
    static func share(_ track: AudioTrack, telegram: TelegramService, lyrics: [LyricLine]?, mode: ShareCardMode, backgroundColor: Color, target: ShareTarget, audioStartTime: Double = 0) async {
        let artworkData = await telegram.highResArtwork(for: track) ?? track.artworkData
        let artworkImage = artworkData.flatMap { UIImage(data: $0) }
        
        let cardLyrics = (mode == .lyrics) ? lyrics : nil
        let card = ShareCard(track: track, artworkImage: artworkImage, lyrics: cardLyrics, mode: mode, backgroundColor: backgroundColor)
            .environment(\.colorScheme, .dark)
            
        let view = ZStack {
            card
        }

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3.0
        
        guard let image = renderer.uiImage else { return }
        guard let pngData = image.pngData() else { return }

        switch target {
        case .instagram:
            let url = URL(string: "instagram-stories://share?source_application=GramMusic")!
            if UIApplication.shared.canOpenURL(url) {
                var items: [String: Any] = [:]
                
                var addedVideo = false
                // Add background video
                if let localURL = try? await telegram.localFile(for: track) {
                    print("🎬 [ShareService] Local audio found. Starting background video generation...")
                    do {
                        let videoURL = try await VideoGenerator.generateBackgroundVideo(
                            audioURL: localURL,
                            startTime: audioStartTime,
                            baseColor: mode == .lyrics ? UIColor(white: 0.2, alpha: 1.0) : UIColor(backgroundColor),
                            coverImage: nil,
                            backgroundImage: image
                        )
                        let videoData = try Data(contentsOf: videoURL)
                        items["com.instagram.sharedSticker.backgroundVideo"] = videoData
                        addedVideo = true
                        print("🎬 [ShareService] Successfully added background video to pasteboard.")
                    } catch {
                        print("❌ [ShareService] Failed to generate background video: \(error)")
                    }
                } else {
                    print("⚠️ [ShareService] Warning: Could not find local audio. Skipping video generation.")
                }
                
                if !addedVideo {
                    items["com.instagram.sharedSticker.backgroundImage"] = pngData
                }
                
                if let link = tmeLink(for: track) {
                    items["com.instagram.sharedSticker.contentURL"] = link
                    items["public.utf8-plain-text"] = link // Copy to clipboard in the same transaction
                }
                
                let pasteboardOptions: [UIPasteboard.OptionsKey: Any] = [.expirationDate: Date().addingTimeInterval(60 * 5)]
                UIPasteboard.general.setItems([items], options: pasteboardOptions)
                
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                presentSystemShare(image: image, pngData: pngData)
            }
            
        case .system:
            presentSystemShare(image: image, pngData: pngData)
        }
    }
    
    private static func presentSystemShare(image: UIImage, pngData: Data) {
        // Create a temporary PNG file url so it guarantees it is shared as a .png instead of arbitrary image type
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("SharedMusic.png")
        do {
            try pngData.write(to: tempUrl)
            let activityVC = UIActivityViewController(activityItems: [tempUrl], applicationActivities: nil)
            
            guard let topVC = topViewController() else { return }
            
            activityVC.popoverPresentationController?.sourceView = topVC.view
            activityVC.popoverPresentationController?.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            activityVC.popoverPresentationController?.permittedArrowDirections = []
            
            topVC.present(activityVC, animated: true)
        } catch {
            print("Failed to write png: \(error)")
        }
    }
    
    private static func topViewController(controller: UIViewController? = nil) -> UIViewController? {
        let root = controller ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?.rootViewController
        
        if let navigationController = root as? UINavigationController {
            return topViewController(controller: navigationController.visibleViewController)
        }
        if let tabController = root as? UITabBarController {
            if let selected = tabController.selectedViewController {
                return topViewController(controller: selected)
            }
        }
        if let presented = root?.presentedViewController {
            return topViewController(controller: presented)
        }
        return root
    }
    
    private static func tmeLink(for track: AudioTrack) -> String? {
        let chatStr = String(track.chatId)
        if chatStr.hasPrefix("-100") {
            let channelId = chatStr.dropFirst(4)
            let realMessageId = track.messageId / 1048576
            return "https://t.me/c/\(channelId)/\(realMessageId)"
        } else if track.chatId < 0 {
            let groupId = chatStr.dropFirst(1)
            let realMessageId = track.messageId / 1048576
            return "https://t.me/c/\(groupId)/\(realMessageId)"
        }
        // Personal chats usually don't have public web links without a username
        return nil
    }
}

enum VideoGeneratorError: Error {
    case invalidAudioFile
    case assetExportFailed
}

final class VideoGenerator {
    /// Generates a 15-second square or vertical video using the provided image and a snippet of the audio file.
    static func generateBackgroundVideo(
        audioURL: URL,
        startTime: Double = 0,
        duration: Double = 15.0,
        baseColor: UIColor,
        coverImage: UIImage? = nil,
        backgroundImage: UIImage? = nil
    ) async throws -> URL {
        print("🎬 [VideoGenerator] Started generating solid background video from \(startTime)s...")
        let audioAsset = AVURLAsset(url: audioURL)
        let audioDuration = try await audioAsset.load(.duration).seconds
        
        let composition = AVMutableComposition()
        
        // Add Audio Track
        guard let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            print("❌ [VideoGenerator] Error: invalidAudioFile")
            throw VideoGeneratorError.invalidAudioFile
        }
        
        // Start from the provided time, clamped to valid range
        let safeStartTime = max(0, min(startTime, audioDuration - 1))
        let actualDuration = min(duration, audioDuration - safeStartTime)
        
        let timeRange = CMTimeRange(
            start: CMTime(seconds: safeStartTime, preferredTimescale: 600),
            duration: CMTime(seconds: actualDuration, preferredTimescale: 600)
        )
        try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
        
        let renderSize = CGSize(width: 1080, height: 1920)
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: renderSize.width,
            AVVideoHeightKey: renderSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 15_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ] as [String: Any]
        ]
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: renderSize.width,
                kCVPixelBufferHeightKey as String: renderSize.height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        writer.add(videoWriterInput)
        
        let audioReader = try AVAssetReader(asset: composition)
        
        let audioSettings: [String: Any]? = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]
        let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        writer.add(audioWriterInput)
        
        let readerAudioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsNonInterleaved: false
        ]
        let audioOutput = AVAssetReaderTrackOutput(track: compositionAudioTrack, outputSettings: readerAudioSettings)
        audioReader.add(audioOutput)
        
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        audioReader.startReading()
        
        struct UnsafeSendable<T>: @unchecked Sendable {
            let value: T
        }
        
        class Tracker {
            var sampleCount = 0
            var frameCount: Int64 = 0
            var isAudioFinished = false
            var isVideoFinished = false
        }
        
        let safeAudioInput = UnsafeSendable(value: audioWriterInput)
        let safeAudioOutput = UnsafeSendable(value: audioOutput)
        let safeVideoInput = UnsafeSendable(value: videoWriterInput)
        let safeAdaptor = UnsafeSendable(value: adaptor)
        let safeTracker = UnsafeSendable(value: Tracker())
        
        // Background image generation
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        var bgCIImage = CIImage(color: CIColor(color: baseColor)).cropped(to: CGRect(origin: .zero, size: renderSize))
        
        if let bgImage = backgroundImage, let ciBg = CIImage(image: bgImage) ?? (bgImage.cgImage.map { CIImage(cgImage: $0) }) {
            // Scale the high-res image down to fit the 1080x1920 video buffer
            let scaleX = renderSize.width / ciBg.extent.width
            let scaleY = renderSize.height / ciBg.extent.height
            let scale = max(scaleX, scaleY)
            let scaledBg = ciBg.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            bgCIImage = scaledBg.cropped(to: CGRect(origin: .zero, size: renderSize))
        } else if let coverImage = coverImage, let ciCover = CIImage(image: coverImage) {
            if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                blurFilter.setValue(ciCover, forKey: kCIInputImageKey)
                blurFilter.setValue(60.0, forKey: kCIInputRadiusKey)
                if let blurred = blurFilter.outputImage {
                    let scaleX = renderSize.width / blurred.extent.width
                    let scaleY = renderSize.height / blurred.extent.height
                    let scale = max(scaleX, scaleY) * 1.2
                    
                    let transformed = blurred
                        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                        .transformed(by: CGAffineTransform(translationX: (renderSize.width - blurred.extent.width * scale) / 2, y: (renderSize.height - blurred.extent.height * scale) / 2))
                        .cropped(to: CGRect(origin: .zero, size: renderSize))
                    
                    // Render to CGImage once for performance in the video loop
                    if let cgImage = ciContext.createCGImage(transformed, from: transformed.extent) {
                        bgCIImage = CIImage(cgImage: cgImage)
                    }
                }
            }
        }
        
        // --- PRE-RENDER STATIC FRAME ONCE ---
        var preRenderedBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(renderSize.width), Int(renderSize.height), kCVPixelFormatType_32BGRA, nil, &preRenderedBuffer)
        if let buffer = preRenderedBuffer {
            CVPixelBufferLockBaseAddress(buffer, [])
            ciContext.render(bgCIImage, to: buffer)
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        let safePreRenderedBuffer = UnsafeSendable(value: preRenderedBuffer)

        print("🎬 [VideoGenerator] Starting video writing loop...")
        
        return try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()
            
            group.enter()
            safeAudioInput.value.requestMediaDataWhenReady(on: DispatchQueue(label: "audioQueue")) {
                while safeAudioInput.value.isReadyForMoreMediaData {
                    if let sampleBuffer = safeAudioOutput.value.copyNextSampleBuffer() {
                        safeAudioInput.value.append(sampleBuffer)
                        safeTracker.value.sampleCount += 1
                    } else {
                        if !safeTracker.value.isAudioFinished {
                            safeTracker.value.isAudioFinished = true
                            safeAudioInput.value.markAsFinished()
                            group.leave()
                        }
                        break
                    }
                }
            }
            
            group.enter()
            safeVideoInput.value.requestMediaDataWhenReady(on: DispatchQueue(label: "videoQueue")) {
                let frameDuration = CMTime(value: 1, timescale: 30)
                let totalFrames = Int64(actualDuration * 30.0)
                
                while safeVideoInput.value.isReadyForMoreMediaData {
                    if safeTracker.value.frameCount >= totalFrames {
                        if !safeTracker.value.isVideoFinished {
                            safeTracker.value.isVideoFinished = true
                            safeVideoInput.value.markAsFinished()
                            group.leave()
                        }
                        break
                    }
                    
                    guard let buffer = safePreRenderedBuffer.value else { 
                        // Fallback break if buffer allocation failed
                        break 
                    }
                    
                    let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(safeTracker.value.frameCount))
                    if safeAdaptor.value.append(buffer, withPresentationTime: presentationTime) {
                        safeTracker.value.frameCount += 1
                    }
                }
            }
            
            group.notify(queue: .main) {
                if let err = writer.error {
                    continuation.resume(throwing: err)
                } else {
                    writer.finishWriting {
                        continuation.resume(returning: outputURL)
                    }
                }
            }
        }
    }
}

extension VideoGenerator {
    static func backdropColor(from image: UIImage) -> UIColor {
        guard let cg = image.cgImage else { return .black }
        let input = CIImage(cgImage: cg)
        let e = input.extent
        let extent = CIVector(x: e.origin.x, y: e.origin.y, z: e.width, w: e.height)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: extent]),
              let output = filter.outputImage else { return .black }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        UIColor(red: CGFloat(px[0]) / 255.0, green: CGFloat(px[1]) / 255.0, blue: CGFloat(px[2]) / 255.0, alpha: 1.0).getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return UIColor(hue: h, saturation: min(s * 1.25, 0.85), brightness: min(max(b, 0.30), 0.52), alpha: 1.0)
    }
}
