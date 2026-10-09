import SwiftUI

/// Interactive 5-Band Equalizer & Sound Presets Sheet.
struct NEqualizerSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerEngine.self) private var player

    private let bands: [EqualizerBand] = [
        EqualizerBand(id: 0, frequency: 60, label: "60 Hz"),
        EqualizerBand(id: 1, frequency: 250, label: "250 Hz"),
        EqualizerBand(id: 2, frequency: 1000, label: "1 kHz"),
        EqualizerBand(id: 3, frequency: 4000, label: "4 kHz"),
        EqualizerBand(id: 4, frequency: 12000, label: "12 kHz")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    masterToggleCard
                    presetPicker
                    responseCurveCard
                    slidersCard
                    resetButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(ScreenBackground())
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                }
            }
        }
    }

    // MARK: - Master Toggle

    private var masterToggleCard: some View {
        HStack {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(player.isEqualizerEnabled ? theme.accentColor : theme.text2)
                .frame(width: 32, height: 32)
                .background(Circle().fill(player.isEqualizerEnabled ? theme.accentColor.opacity(0.18) : theme.elev))

            VStack(alignment: .leading, spacing: 2) {
                Text("Equalizer")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(player.isEqualizerEnabled ? player.equalizerPreset.rawValue : "Disabled")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text2)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { player.isEqualizerEnabled },
                set: { player.setEqualizerEnabled($0) }
            ))
            .labelsHidden()
            .tint(theme.accentColor)
        }
        .padding(16)
        .nocturneGlassCard(theme)
    }

    // MARK: - Presets Carousel

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PRESETS")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(theme.text2)
                .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EqualizerPreset.allCases, id: \.self) { preset in
                        let isSelected = player.equalizerPreset == preset
                        Button {
                            player.setEqualizerPreset(preset)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            HStack(spacing: 6) {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                Text(preset.rawValue)
                                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                            }
                            .foregroundStyle(isSelected ? theme.accentText : theme.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(isSelected ? theme.accentColor : theme.elev)
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? Color.clear : theme.hairline, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!player.isEqualizerEnabled)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .opacity(player.isEqualizerEnabled ? 1.0 : 0.45)
    }

    // MARK: - Live Response Curve Graph

    private var responseCurveCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FREQUENCY RESPONSE")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(theme.text2)
                Spacer()
                Text("±12 dB")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.text2.opacity(0.8))
            }

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let midY = h / 2.0
                let gains = player.equalizerGains

                ZStack {
                    // Grid reference lines: +12dB, 0dB, -12dB
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 0))
                        p.addLine(to: CGPoint(x: w, y: 0))
                        p.move(to: CGPoint(x: 0, y: midY))
                        p.addLine(to: CGPoint(x: w, y: midY))
                        p.move(to: CGPoint(x: 0, y: h))
                        p.addLine(to: CGPoint(x: w, y: h))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 0.75, dash: [4, 4]))
                    .foregroundStyle(theme.hairline)

                    // Spline curve through the 5 band gains
                    let points = (0..<5).map { i -> CGPoint in
                        let x = w * (CGFloat(i) + 0.5) / 5.0
                        let gain = CGFloat(gains.indices.contains(i) ? gains[i] : 0)
                        let y = midY - (gain / 12.0) * (midY - 8)
                        return CGPoint(x: x, y: y)
                    }

                    // Curve path
                    Path { p in
                        guard !points.isEmpty else { return }
                        p.move(to: CGPoint(x: 0, y: points[0].y))
                        p.addLine(to: points[0])
                        for i in 0..<(points.count - 1) {
                            let p0 = points[i]
                            let p1 = points[i + 1]
                            let c1 = CGPoint(x: (p0.x + p1.x) / 2, y: p0.y)
                            let c2 = CGPoint(x: (p0.x + p1.x) / 2, y: p1.y)
                            p.addCurve(to: p1, control1: c1, control2: c2)
                        }
                        p.addLine(to: CGPoint(x: w, y: points.last?.y ?? midY))
                    }
                    .stroke(
                        player.isEqualizerEnabled ? theme.accentColor : theme.text2.opacity(0.5),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )

                    // Control point dots
                    ForEach(0..<points.count, id: \.self) { i in
                        Circle()
                            .fill(player.isEqualizerEnabled ? theme.accentColor : theme.text2)
                            .frame(width: 7, height: 7)
                            .position(points[i])
                    }
                }
            }
            .frame(height: 90)
            .padding(.top, 4)
        }
        .padding(14)
        .nocturneGlassCard(theme)
        .opacity(player.isEqualizerEnabled ? 1.0 : 0.45)
    }

    // MARK: - 5-Band Vertical Sliders

    private var slidersCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    let band = bands[i]
                    let gain = player.equalizerGains.indices.contains(i) ? player.equalizerGains[i] : 0

                    BandSliderColumn(
                        band: band,
                        gain: gain,
                        accentColor: theme.accentColor,
                        disabled: !player.isEqualizerEnabled,
                        onChanged: { newGain in
                            player.setEqualizerGain(newGain, at: i)
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .nocturneGlassCard(theme)
        .opacity(player.isEqualizerEnabled ? 1.0 : 0.45)
    }

    // MARK: - Reset Button

    private var resetButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                player.resetEqualizer()
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                Text("Reset to Flat")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(theme.text2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(theme.elev)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!player.isEqualizerEnabled || player.equalizerPreset == .flat)
        .opacity(player.isEqualizerEnabled && player.equalizerPreset != .flat ? 1.0 : 0.4)
    }
}

// MARK: - Band Slider Column

private struct BandSliderColumn: View {
    @Environment(\.theme) private var theme
    let band: EqualizerBand
    let gain: Float
    let accentColor: Color
    let disabled: Bool
    let onChanged: (Float) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false

    private let sliderHeight: CGFloat = 140

    var body: some View {
        VStack(spacing: 8) {
            // Decibel readout
            Text(String(format: "%+.1f dB", gain))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(abs(gain) > 0.1 ? accentColor : theme.text2)
                .frame(height: 14)

            // Custom Vertical Slider
            GeometryReader { geo in
                let h = geo.size.height
                let midY = h / 2.0
                let normalized = CGFloat(gain / 12.0) // -1.0 ... +1.0
                let thumbY = midY - normalized * (midY - 12)

                ZStack {
                    // Track Background
                    Capsule()
                        .fill(theme.hairline.opacity(0.8))
                        .frame(width: 6, height: h)

                    // Center 0 dB detent tick
                    Rectangle()
                        .fill(theme.text2.opacity(0.6))
                        .frame(width: 14, height: 1.5)
                        .position(x: geo.size.width / 2, y: midY)

                    // Active Fill from center to thumb
                    let fillHeight = abs(thumbY - midY)
                    let fillCenterY = (thumbY + midY) / 2
                    Capsule()
                        .fill(accentColor)
                        .frame(width: 6, height: fillHeight)
                        .position(x: geo.size.width / 2, y: fillCenterY)

                    // Thumb Knob
                    Circle()
                        .fill(Color.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: Color.black.opacity(0.25), radius: 4, y: 2)
                        .overlay(
                            Circle()
                                .strokeBorder(accentColor, lineWidth: isDragging ? 2.5 : 1.5)
                        )
                        .position(x: geo.size.width / 2, y: thumbY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !disabled else { return }
                            isDragging = true
                            let locationY = value.location.y
                            let clampedY = max(12, min(h - 12, locationY))
                            let fraction = (midY - clampedY) / (midY - 12)
                            var newGain = Float(fraction * 12.0)
                            // Snap to 0 dB within deadzone
                            if abs(newGain) < 0.4 { newGain = 0 }
                            onChanged(min(12.0, max(-12.0, newGain)))
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
            }
            .frame(height: sliderHeight)

            // Frequency Label
            Text(band.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text)
                .lineLimit(1)
        }
    }
}
