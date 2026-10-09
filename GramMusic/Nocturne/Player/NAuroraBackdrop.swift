import SwiftUI

// The ambient Aurora backdrop behind Now Playing: a slow gradient drift modulated by the audio
// level. Split out of NNowPlayingView.swift.
//
// Performance note: the TimelineView is paused when playback is paused (a still picture doesn't
// need 30fps of blend-mode compositing) and the audio level is quantised by the caller, because
// every distinct value invalidates this view on top of the timeline's own schedule.

struct AuroraBackdrop: View {
    let baseColor: Color
    @Environment(PlayerEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // We extract the actual renderer to apply a smoothing animation exclusively to the audioLevel.
        // Quantise: `audioLevel` is published ~30×/sec and every distinct value invalidates this
        // view on top of the TimelineView's own schedule. Eighths are indistinguishable once
        // `.animation` smooths them, and collapse most of those invalidations.
        AuroraAnimatedRenderer(baseColor: baseColor,
                               audioLevel: (player.audioLevel * 8).rounded() / 8,
                               reduceMotion: reduceMotion,
                               isPlaying: player.isPlaying)
    }
}

struct AuroraAnimatedRenderer: View {
    let baseColor: Color
    var audioLevel: Double
    let reduceMotion: Bool
    /// Paused playback holds a still picture, so the 30fps schedule was repainting three
    /// full-screen gradients (two of them `.blendMode(.screen)`, forcing offscreen compositing)
    /// for an image that no longer changes.
    var isPlaying: Bool = true

    var body: some View {
        // Using TimelineView guarantees continuous animation without depending on .onAppear lifecycles
        TimelineView(.animation(minimumInterval: 1/30.0, paused: reduceMotion || !isPlaying)) { context in
            let date = context.date.timeIntervalSince1970
            // Slowed down the base rotation slightly so it feels more relaxed and clean
            let phase = reduceMotion ? 0 : date * 0.5 
            
            // Audio level creates a "pulse" effect on top of the slow aurora drift.
            // Reduced the intensity so it feels smooth and clean rather than fast and flashy.
            let pulse = reduceMotion ? 0.0 : audioLevel * 0.08
            
            ZStack {
                // Base background gradient
                LinearGradient(
                    colors: [baseColor, baseColor.blended(with: Color(hex: 0x07070B), amount: 0.45), Color(hex: 0x07070B)],
                    startPoint: .top, endPoint: .bottom)
                
                if !reduceMotion {
                    // Animated, shifting radial gradient (Aurora #1)
                    RadialGradient(
                        colors: [baseColor.opacity(0.4 + pulse), .clear],
                        center: UnitPoint(x: 0.5 + (sin(phase) * 0.4), y: 0.2 + (cos(phase) * 0.3)),
                        startRadius: 0, endRadius: 500 + (pulse * 600))
                        .blendMode(.screen)
                    
                    // Animated, shifting radial gradient (Aurora #2)
                    RadialGradient(
                        colors: [baseColor.opacity(0.3 + pulse), .clear],
                        center: UnitPoint(x: 0.5 - (cos(phase * 0.7) * 0.4), y: 0.4 + (sin(phase * 0.8) * 0.4)),
                        startRadius: 0, endRadius: 600 + (pulse * 600))
                        .blendMode(.screen)
                } else {
                    RadialGradient(colors: [Color.white.opacity(0.18), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.02),
                                   startRadius: 0, endRadius: 380)
                }
                
                // The subtle top light glare (existing), slightly animated
                RadialGradient(
                    colors: [Color.white.opacity(0.18 + pulse * 0.5), .clear],
                    center: UnitPoint(x: 0.5 + (reduceMotion ? 0 : sin(phase * 0.5) * 0.1), y: 0.02),
                    startRadius: 0, endRadius: 380 + (pulse * 400))
            }
        }
        // This is the magic: It acts as a low-pass filter! 
        // Rapid 30fps jumps in audioLevel are smoothly interpolated by a relaxed spring,
        // turning harsh flashes into a clean, gentle breathing effect.
        .animation(.spring(response: 0.8, dampingFraction: 0.9), value: audioLevel)
    }
}
