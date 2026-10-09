import SwiftUI

struct NMarqueeText<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: () -> Content
    
    var spacing: CGFloat
    var velocity: Double
    var delay: Double
    
    @State private var offset: CGFloat = 0
    @State private var contentSize: CGSize = .zero
    @State private var isOverflowing = false
    @State private var animationTask: Task<Void, Never>?
    
    init(spacing: CGFloat = 30, velocity: Double = 30, delay: Double = 2.0, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.velocity = velocity
        self.delay = delay
        self.content = content
    }
    
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: spacing) {
                content()
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        GeometryReader { contentProxy in
                            Color.clear
                                .preference(key: MarqueeSizePreferenceKey.self, value: contentProxy.size)
                        }
                    )
                
                if isOverflowing && !reduceMotion {
                    content()
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityHidden(true)
                }
            }
            .offset(x: offset)
            .frame(width: proxy.size.width, alignment: .leading)
            .clipped()
            .onPreferenceChange(MarqueeSizePreferenceKey.self) { newSize in
                let nowOverflowing = newSize.width > proxy.size.width
                
                contentSize = newSize
                isOverflowing = nowOverflowing
                
                if nowOverflowing {
                    startAnimation(width: newSize.width)
                } else {
                    stopAnimation()
                }
            }
            .onChange(of: proxy.size.width) { _, newContainerWidth in
                let nowOverflowing = contentSize.width > newContainerWidth
                if isOverflowing != nowOverflowing {
                    isOverflowing = nowOverflowing
                    if nowOverflowing {
                        startAnimation(width: contentSize.width)
                    } else {
                        stopAnimation()
                    }
                }
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { stopAnimation() }
                else if isOverflowing { startAnimation(width: contentSize.width) }
            }
            .onDisappear {
                animationTask?.cancel()
            }
        }
        .frame(height: contentSize.height > 0 ? contentSize.height : nil)
    }
    
    private func startAnimation(width: CGFloat) {
        animationTask?.cancel()
        guard !reduceMotion else { stopAnimation(); return }
        
        withAnimation(.linear(duration: 0)) {
            offset = 0
        }
        
        animationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            
            if isOverflowing && !reduceMotion {
                let duration = Double(width + spacing) / velocity
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    offset = -(width + spacing)
                }
            }
        }
    }
    
    private func stopAnimation() {
        animationTask?.cancel()
        withAnimation(.linear(duration: 0)) {
            offset = 0
        }
    }
}

struct MarqueeSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
