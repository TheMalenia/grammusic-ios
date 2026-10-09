import SwiftUI

/// Follows playback and scrubbing. The compact preview leaves touch scrolling to the player;
/// the expanded list also lets listeners seek by tapping a line.
struct NSyncedLyricsList: View {
    let lines: [LyricLine]
    let isPreview: Bool
    @State private var followsPlayback = true

    @Environment(PlayerEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var previewPadding = 76.0

    private var activeIndex: Int? {
        let time = player.currentTime
        return lines.lastIndex { ($0.time ?? .infinity) <= time }
    }

    var body: some View {
        let active = activeIndex
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: isPreview ? 16 : 24) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Group {
                                if isPreview {
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                } else {
                                    Button(action: { seek(to: line) }) {
                                        Text(line.text.isEmpty ? "♪" : line.text)
                                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Plays from this line")
                                }
                            }
                            .font(isPreview ? .title2.weight(.bold) : .title.weight(.bold))
                            .foregroundStyle(.white.opacity(index == active ? 1 : 0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(index == active ? .isSelected : [])
                            .id(index)
                        }
                    }
                    .padding(.horizontal, isPreview ? 0 : 24)
                    .padding(.top, isPreview ? 0 : 80)
                    .padding(.bottom, isPreview ? previewPadding : 80)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { value in
                    if !isPreview && abs(value.translation.height) > 8 { followsPlayback = false }
                }, including: isPreview ? .none : .all)
                .scrollDisabled(isPreview)
                .scrollIndicators(.hidden)
                .task {
                    proxy.scrollTo(active ?? 0, anchor: scrollAnchor(for: active))
                }
                .onChange(of: active) { _, newIndex in
                    guard isPreview || followsPlayback else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                        proxy.scrollTo(newIndex ?? 0, anchor: scrollAnchor(for: newIndex))
                    }
                }
                .onChange(of: followsPlayback) { _, following in
                    guard following else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                        proxy.scrollTo(active ?? 0, anchor: scrollAnchor(for: active))
                    }
                }
                .accessibilityAction(named: "Stop following lyrics") {
                    if !isPreview { followsPlayback = false }
                }
            }
        }
    }

    private func scrollAnchor(for index: Int?) -> UnitPoint {
        isPreview && (index ?? 0) == 0 ? .top : .center
    }

    private func seek(to line: LyricLine) {
        followsPlayback = true
        if let time = line.time { player.seek(to: time) }
    }
}
