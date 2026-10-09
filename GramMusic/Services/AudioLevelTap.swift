import AVFoundation
import Accelerate
import os

/// Biquad IIR filter coefficients for Audio EQ (Robert Bristow-Johnson Audio EQ Cookbook)
public struct BiquadCoefficients: Sendable {
    public var b0: Float = 1
    public var b1: Float = 0
    public var b2: Float = 0
    public var a1: Float = 0
    public var a2: Float = 0

    public init(b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// A pass-through filter — no point spending cycles on it.
    @inline(__always)
    public var isIdentity: Bool { b0 == 1 && b1 == 0 && b2 == 0 && a1 == 0 && a2 == 0 }

    public static func lowShelf(frequency: Float, sampleRate: Float, gainDB: Float, q: Float = 0.707) -> BiquadCoefficients {
        guard gainDB != 0, sampleRate > 0 else { return BiquadCoefficients() }
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)
        let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha

        let b0 = A * ((A + 1.0) - (A - 1.0) * cosW0 + twoSqrtAAlpha)
        let b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW0)
        let b2 = A * ((A + 1.0) - (A - 1.0) * cosW0 - twoSqrtAAlpha)
        let a0 = (A + 1.0) + (A - 1.0) * cosW0 + twoSqrtAAlpha
        let a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW0)
        let a2 = (A + 1.0) + (A - 1.0) * cosW0 - twoSqrtAAlpha

        guard a0 != 0 else { return BiquadCoefficients() }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    public static func peaking(frequency: Float, sampleRate: Float, gainDB: Float, q: Float = 1.0) -> BiquadCoefficients {
        guard gainDB != 0, sampleRate > 0 else { return BiquadCoefficients() }
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)

        let b0 = 1.0 + alpha * A
        let b1 = -2.0 * cosW0
        let b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha / A

        guard a0 != 0 else { return BiquadCoefficients() }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    public static func highShelf(frequency: Float, sampleRate: Float, gainDB: Float, q: Float = 0.707) -> BiquadCoefficients {
        guard gainDB != 0, sampleRate > 0 else { return BiquadCoefficients() }
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Float.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)
        let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha

        let b0 = A * ((A + 1.0) + (A - 1.0) * cosW0 + twoSqrtAAlpha)
        let b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW0)
        let b2 = A * ((A + 1.0) + (A - 1.0) * cosW0 - twoSqrtAAlpha)
        let a0 = (A + 1.0) - (A - 1.0) * cosW0 + twoSqrtAAlpha
        let a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW0)
        let a2 = (A + 1.0) - (A - 1.0) * cosW0 - twoSqrtAAlpha

        guard a0 != 0 else { return BiquadCoefficients() }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

/// Filter delay state for a single band on a single audio channel.
public struct BiquadState: Sendable {
    public var d1: Float = 0
    public var d2: Float = 0

    public init(d1: Float = 0, d2: Float = 0) {
        self.d1 = d1
        self.d2 = d2
    }

    @inline(__always)
    public mutating func process(_ x: Float, coeffs: BiquadCoefficients) -> Float {
        // Transposed Direct Form II
        let y = coeffs.b0 * x + d1
        d1 = coeffs.b1 * x - coeffs.a1 * y + d2
        d2 = coeffs.b2 * x - coeffs.a2 * y
        return y
    }

    public mutating func reset() {
        d1 = 0
        d2 = 0
    }
}

/// Realtime audio-level meter and 5-band Equalizer DSP processor.
///
/// Splices an `MTAudioProcessingTap` into the player item's audio mix. In real-time on the
/// audio thread, it runs 5 Biquad IIR filters for frequency equalization and calculates smoothed
/// RMS loudness for the live animated equalizer visualizer bars.
final class AudioLevelTap: @unchecked Sendable {

    static let bandCount = 5
    private static let maxChannels = 8

    /// State shared between the control thread (main actor: preset/gain changes, level reads) and
    /// the realtime audio render thread.
    ///
    /// **Realtime discipline.** `tapProcess` runs on the audio render thread, where blocking on a
    /// mutex risks priority inversion and dropouts, and any heap allocation is forbidden. So:
    ///
    /// - Control-side fields (`pendingCoeffs`, `level`) are guarded by an `os_unfair_lock` that the
    ///   audio thread only ever **tries**. A failed try is harmless: coefficients are picked up on
    ///   the next buffer, and a skipped level sample is invisible in a 30fps meter.
    /// - Audio-side fields (`activeCoeffs`, `states`, `isFloat`, `sampleRate`) are raw buffers
    ///   owned solely by the media pipeline. `tapPrepare` and `tapProcess` are serialized against
    ///   each other, so they need no synchronisation — and no Swift `Array`, whose subscript
    ///   assignment would do CoW/uniqueness work in the render callback.
    ///
    /// The previous version mutated a nested `[[BiquadState]]` from the render thread while the
    /// control thread wrote the same array under a lock (a genuine data race), and took an
    /// `NSLock` twice per buffer.
    final class Box: @unchecked Sendable {

        // MARK: Control side — guarded by `lock`
        private let lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        private var pendingCoeffs = [BiquadCoefficients](repeating: .init(), count: bandCount)
        private var pendingEnabled = false
        private var gains = [Float](repeating: 0, count: bandCount)
        /// Bumped whenever `pendingCoeffs` changes; the audio thread compares against its own copy.
        private var version: Int32 = 0
        private var level: Float = 0

        // MARK: Audio side — touched only by tapPrepare / tapProcess
        var isFloat = true
        var sampleRate: Float = 44100
        var eqActive = false
        private(set) var appliedVersion: Int32 = -1
        let activeCoeffs = UnsafeMutablePointer<BiquadCoefficients>.allocate(capacity: bandCount)
        /// Flat `channel * bandCount + band` filter delay state.
        private(set) var states = UnsafeMutablePointer<BiquadState>.allocate(capacity: maxChannels * bandCount)
        private(set) var stateChannels = maxChannels

        init() {
            lock.initialize(to: os_unfair_lock_s())
            activeCoeffs.initialize(repeating: .init(), count: Self.bandCount)
            states.initialize(repeating: .init(), count: Self.maxChannels * Self.bandCount)
        }

        deinit {
            activeCoeffs.deinitialize(count: Self.bandCount)
            activeCoeffs.deallocate()
            states.deinitialize(count: stateChannels * Self.bandCount)
            states.deallocate()
            lock.deallocate()
        }

        private static let bandCount = AudioLevelTap.bandCount
        private static let maxChannels = AudioLevelTap.maxChannels

        // MARK: Control-thread API

        func setEqualizer(enabled: Bool, gains newGains: [Float]) {
            os_unfair_lock_lock(lock)
            pendingEnabled = enabled
            for i in 0..<Self.bandCount {
                gains[i] = newGains.indices.contains(i) ? newGains[i] : 0
            }
            recomputeLocked()
            os_unfair_lock_unlock(lock)
        }

        /// Re-derive coefficients for a new sample rate (called from `tapPrepare`).
        func updateSampleRate(_ rate: Float) {
            sampleRate = rate
            os_unfair_lock_lock(lock)
            recomputeLocked()
            os_unfair_lock_unlock(lock)
        }

        var currentLevel: Float {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return level
        }

        /// `sampleRate` is read here from the control thread. It is only ever *written* by
        /// `updateSampleRate`, and a stale read just means one more recompute on the next change.
        private func recomputeLocked() {
            version &+= 1
            guard pendingEnabled, sampleRate > 0 else {
                for i in 0..<Self.bandCount { pendingCoeffs[i] = BiquadCoefficients() }
                return
            }
            pendingCoeffs[0] = .lowShelf(frequency: 60, sampleRate: sampleRate, gainDB: gains[0])
            pendingCoeffs[1] = .peaking(frequency: 250, sampleRate: sampleRate, gainDB: gains[1])
            pendingCoeffs[2] = .peaking(frequency: 1000, sampleRate: sampleRate, gainDB: gains[2])
            pendingCoeffs[3] = .peaking(frequency: 4000, sampleRate: sampleRate, gainDB: gains[3])
            pendingCoeffs[4] = .highShelf(frequency: 12000, sampleRate: sampleRate, gainDB: gains[4])
        }

        // MARK: Audio-thread API (never blocks)

        /// Pick up new coefficients if the control thread published any *and* the lock is free.
        /// Returns whether the EQ should be applied to this buffer.
        func refreshCoefficientsIfNeeded() -> Bool {
            if os_unfair_lock_trylock(lock) {
                if version != appliedVersion {
                    for i in 0..<Self.bandCount { activeCoeffs[i] = pendingCoeffs[i] }
                    appliedVersion = version
                    eqActive = pendingEnabled
                }
                os_unfair_lock_unlock(lock)
            }
            guard eqActive else { return false }
            for i in 0..<Self.bandCount where !activeCoeffs[i].isIdentity { return true }
            return false
        }

        /// Publish a level sample. Dropped if the control thread holds the lock — a missed frame
        /// in a VU meter is imperceptible, and blocking here is not an option.
        func publishLevel(_ boosted: Float) {
            guard os_unfair_lock_trylock(lock) else { return }
            level = boosted > level ? boosted : level * 0.82 + boosted * 0.18
            os_unfair_lock_unlock(lock)
        }

        /// Resize the delay-state buffer for a new channel count and clear it. Audio side only.
        func resetStates(channels: Int) {
            let wanted = max(1, min(channels, Self.maxChannels))
            if wanted != stateChannels {
                states.deinitialize(count: stateChannels * Self.bandCount)
                states.deallocate()
                states = .allocate(capacity: wanted * Self.bandCount)
                states.initialize(repeating: .init(), count: wanted * Self.bandCount)
                stateChannels = wanted
            } else {
                for i in 0..<(stateChannels * Self.bandCount) { states[i] = BiquadState() }
            }
        }
    }

    let box = Box()
    private var mix: AVAudioMix?

    /// Latest smoothed loudness, 0…1. Safe to read from any thread.
    var currentLevel: Float { box.currentLevel }

    /// Update equalizer state in real time.
    func updateEqualizer(enabled: Bool, gains: [Float]) {
        box.setEqualizer(enabled: enabled, gains: gains)
    }

    /// Build and attach the tap to `item`'s first audio track.
    @MainActor
    func install(on item: AVPlayerItem, eqEnabled: Bool = false, gains: [Float] = [0, 0, 0, 0, 0]) async {
        box.setEqualizer(enabled: eqEnabled, gains: gains)

        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }

        let boxPtr = Unmanaged.passRetained(box).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: boxPtr,
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: nil,
            process: tapProcess)

        var tapOut: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tapOut)
        guard status == noErr, let tap = tapOut else {
            Unmanaged<Box>.fromOpaque(boxPtr).release()
            return
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        self.mix = mix
        item.audioMix = mix
    }
}

// MARK: - Realtime callbacks (run off the main actor on the audio render thread)

private func tapInit(_ tap: MTAudioProcessingTap,
                     _ clientInfo: UnsafeMutableRawPointer?,
                     _ tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<AudioLevelTap.Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func tapPrepare(_ tap: MTAudioProcessingTap,
                        _ maxFrames: CMItemCount,
                        _ format: UnsafePointer<AudioStreamBasicDescription>) {
    let box = Unmanaged<AudioLevelTap.Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    box.isFloat = (format.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let sr = Float(format.pointee.mSampleRate)
    box.updateSampleRate(sr > 0 ? sr : 44100)
    box.resetStates(channels: Int(format.pointee.mChannelsPerFrame))
}

private func tapProcess(_ tap: MTAudioProcessingTap,
                        _ numberFrames: CMItemCount,
                        _ flags: MTAudioProcessingTapFlags,
                        _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                        _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                        _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }

    let box = Unmanaged<AudioLevelTap.Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()

    // Non-blocking: picks up newly published coefficients only if the lock happens to be free.
    let hasEQ = box.refreshCoefficientsIfNeeded()
    let coeffs = box.activeCoeffs
    let states = box.states
    let bands = AudioLevelTap.bandCount
    let isFloat = box.isFloat
    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)

    var sumRMS: Float = 0
    var counted = 0

    for ch in 0..<min(buffers.count, box.stateChannels) {
        let buffer = buffers[ch]
        guard let data = buffer.mData else { continue }
        let channelStates = states + (ch * bands)
        var rms: Float = 0

        if isFloat {
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard n > 0 else { continue }
            let ptr = data.assumingMemoryBound(to: Float.self)

            if hasEQ {
                for i in 0..<n {
                    var s = ptr[i]
                    for band in 0..<bands {
                        s = channelStates[band].process(s, coeffs: coeffs[band])
                    }
                    if s > 1.0 {
                        s = 1.0 - (1.0 / (s + 0.5)) * 0.5
                    } else if s < -1.0 {
                        s = -1.0 + (1.0 / (-s + 0.5)) * 0.5
                    }
                    ptr[i] = max(-1.0, min(1.0, s))
                }
            }

            vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(n))
        } else {
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            guard n > 0 else { continue }
            let p = data.assumingMemoryBound(to: Int16.self)

            if hasEQ {
                for i in 0..<n {
                    var s = Float(p[i]) / 32768.0
                    for band in 0..<bands {
                        s = channelStates[band].process(s, coeffs: coeffs[band])
                    }
                    let clamped = max(-1.0, min(1.0, s))
                    p[i] = Int16(clamped * 32767.0)
                }
            }

            var acc: Float = 0
            for i in 0..<n { let s = Float(p[i]) / 32768.0; acc += s * s }
            rms = (acc / Float(n)).squareRoot()
        }

        sumRMS += rms
        counted += 1
    }

    guard counted > 0 else { return }

    // RMS rarely approaches 1.0 for music, so boost into a usable range, then clamp.
    // Fast attack, slower release: bars snap up on transients then ease down — reads as "beat".
    box.publishLevel(min(1, (sumRMS / Float(counted)) * 3.2))
}

