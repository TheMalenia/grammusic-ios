import Foundation

/// The audio container identified from a file's magic bytes — the single source of truth for
/// "what is this file really," shared by the two callers that used to each carry their own copy
/// of the signature table:
///   * `TDLibTelegramBackend.detectedExtension` — to pick the *real* extension for AVFoundation
///     (TDLib names files after the extension-less / mislabeled Telegram `file_name`).
///   * `PlayerEngine.sniffFormat` — to log what a failed `AVPlayerItem` actually was.
///
/// AVFoundation chooses its demuxer from the file extension, so handing it the right one is the
/// difference between playback and a `-11828 Cannot Open`.
enum AudioFormat: Sendable {
    case mp3, m4a, wav, aiff, flac, ogg, matroska

    /// The path extension to give a local file so AVFoundation picks the correct demuxer.
    var fileExtension: String {
        switch self {
        case .mp3: "mp3"
        case .m4a: "m4a"
        case .wav: "wav"
        case .aiff: "aiff"
        case .flac: "flac"
        case .ogg: "ogg"
        case .matroska: "mkv"
        }
    }

    /// Whether AVFoundation can actually decode this container. Telegram/Swiftgram play everything
    /// by bundling FFmpeg; we don't, so Opus/Ogg and Matroska/WebM are detected but unplayable.
    var isPlayableByAVFoundation: Bool {
        switch self {
        case .ogg, .matroska: false
        default: true
        }
    }

    /// A short, user-facing name for error messages (e.g. "Opus / Ogg isn't supported yet").
    var displayName: String {
        switch self {
        case .mp3: "MP3"
        case .m4a: "M4A"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .flac: "FLAC"
        case .ogg: "Opus / Ogg"
        case .matroska: "Matroska / WebM"
        }
    }

    /// Best-effort container guess from a path/file extension — used on the streaming path,
    /// where there are no local bytes to sniff yet. `nil` for unknown extensions.
    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "mp3":                 self = .mp3
        case "m4a", "mp4", "aac":   self = .m4a
        case "wav", "wave":         self = .wav
        case "aiff", "aif":         self = .aiff
        case "flac":                self = .flac
        case "ogg", "opus":         self = .ogg
        case "mkv", "webm":         self = .matroska
        default:                    return nil
        }
    }

    /// A short human label for logs.
    var diagnosticLabel: String {
        switch self {
        case .mp3: "MP3"
        case .m4a: "MP4/M4A"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .flac: "FLAC"
        case .ogg: "OGG (Opus/Vorbis) — unsupported by AVFoundation"
        case .matroska: "Matroska/WebM — unsupported by AVFoundation"
        }
    }

    /// Sniff the container from the first bytes of the file. `nil` if the header is inconclusive.
    static func sniff(path: String) -> AudioFormat? {
        guard let bytes = magicBytes(atPath: path) else { return nil }
        return match(bytes)
    }

    /// Sniff a local file URL; `nil` for non-file URLs (streaming/remote).
    static func sniff(url: URL) -> AudioFormat? {
        url.isFileURL ? sniff(path: url.path) : nil
    }

    /// A log-friendly description of the file: its detected container, the raw magic bytes when
    /// unrecognised, or a read-failure note.
    static func describe(path: String) -> String {
        guard let bytes = magicBytes(atPath: path) else { return "unreadable" }
        if let format = match(bytes) { return format.diagnosticLabel }
        let hex = bytes.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
        return "unknown (magic: \(hex))"
    }

    private static func magicBytes(atPath path: String) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let bytes = [UInt8]((try? handle.read(upToCount: 12)) ?? Data())
        return bytes.count >= 4 ? bytes : nil
    }

    private static func match(_ bytes: [UInt8]) -> AudioFormat? {
        func has(_ ascii: String, at offset: Int = 0) -> Bool {
            let sig = Array(ascii.utf8)
            guard bytes.count >= offset + sig.count else { return false }
            return Array(bytes[offset..<offset + sig.count]) == sig
        }
        if has("OggS") { return .ogg }                              // Opus/Vorbis
        if has("fLaC") { return .flac }
        if has("RIFF") { return .wav }
        if has("FORM") { return .aiff }
        if has("ftyp", at: 4) { return .m4a }                       // ISO-BMFF: MP4/M4A
        if has("ID3") { return .mp3 }                               // ID3-tagged MP3
        if bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0 { return .mp3 }   // MPEG frame sync
        if bytes.count >= 4, bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
            return .matroska
        }
        return nil
    }
}
