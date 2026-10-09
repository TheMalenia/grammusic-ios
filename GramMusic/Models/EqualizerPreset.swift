import Foundation

/// One frequency band in the 5-band equalizer.
public struct EqualizerBand: Identifiable, Hashable, Sendable {
    public let id: Int
    /// Center / cutoff frequency in Hz (60, 250, 1000, 4000, 12000).
    public let frequency: Float
    /// Display label for UI (e.g. "60 Hz", "1 kHz").
    public let label: String
    /// Gain in decibels (-12.0 ... +12.0 dB).
    public var gain: Float

    public init(id: Int, frequency: Float, label: String, gain: Float = 0) {
        self.id = id
        self.frequency = frequency
        self.label = label
        self.gain = gain
    }
}

/// Standard audio equalizer presets.
public enum EqualizerPreset: String, CaseIterable, Identifiable, Sendable, Equatable, Hashable {
    case flat = "Flat"
    case bassBooster = "Bass Booster"
    case bassReducer = "Bass Reducer"
    case vocalBooster = "Vocal Booster"
    case trebleBooster = "Treble Booster"
    case acoustic = "Acoustic"
    case rock = "Rock"
    case pop = "Pop"
    case electronic = "Electronic"
    case hipHop = "Hip-Hop"
    case jazz = "Jazz"
    case classical = "Classical"
    case custom = "Custom"

    public var id: String { rawValue }

    /// Standard frequency centers for 5-band EQ: 60Hz, 250Hz, 1kHz, 4kHz, 12kHz.
    public static let defaultFrequencies: [Float] = [60, 250, 1000, 4000, 12000]
    public static let bandLabels: [String] = ["60 Hz", "250 Hz", "1 kHz", "4 kHz", "12 kHz"]

    /// Default gain values (in dB) for each of the 5 bands.
    public var gains: [Float] {
        switch self {
        case .flat:          return [0, 0, 0, 0, 0]
        case .bassBooster:   return [6.0, 4.5, 1.0, -1.0, -2.0]
        case .bassReducer:   return [-6.0, -4.0, 0.0, 0.0, 0.0]
        case .vocalBooster:  return [-2.0, 1.0, 5.0, 3.5, 1.0]
        case .trebleBooster: return [-1.5, 0.0, 1.0, 4.0, 6.0]
        case .acoustic:      return [3.5, 2.5, 1.0, 3.0, 4.0]
        case .rock:          return [5.0, 3.0, -1.0, 3.0, 5.0]
        case .pop:           return [2.0, 3.0, 4.0, 2.0, -1.0]
        case .electronic:    return [6.0, 4.5, 0.0, 3.0, 5.0]
        case .hipHop:        return [6.0, 4.0, 1.0, 2.0, 3.0]
        case .jazz:          return [3.0, 2.0, 1.0, 2.0, 3.0]
        case .classical:     return [4.0, 2.0, 0.0, 2.0, 4.0]
        case .custom:        return [0, 0, 0, 0, 0]
        }
    }
}
