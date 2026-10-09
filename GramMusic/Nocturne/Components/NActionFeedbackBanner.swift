import SwiftUI

struct NActionFeedbackBanner: ViewModifier {
    @Environment(NActionFeedback.self) private var feedback
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showQueue = false
    var bottomClearance: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message = feedback.message {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { Text(message); actions }
                        VStack(alignment: .leading, spacing: 8) { Text(message); actions }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.elev, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.hairline))
                    .shadow(color: theme.shadow.opacity(0.4), radius: 12, y: 4)
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomClearance)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .accessibilityElement(children: .contain)
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: feedback.id)
            .task(id: feedback.id) {
                let id = feedback.id
                guard feedback.message != nil else { return }
                if let announcement = feedback.takeAnnouncement() {
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
                // Give assistive-technology users longer to reach Undo.
                try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 12 : 6))
                guard !Task.isCancelled else { return }
                feedback.dismiss(ifMatching: id)
            }
            .sheet(isPresented: $showQueue) { NQueueView() }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if feedback.undo != nil {
                Button("Undo", action: feedback.undoLastAction)
                    .frame(minWidth: 44, minHeight: 44)
            }
            if feedback.offersQueue {
                Button("View queue") { feedback.dismiss(); showQueue = true }
                    .frame(minHeight: 44)
            }
            Button("Dismiss", systemImage: "xmark") { feedback.dismiss() }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accentColor)
    }
}

extension View {
    func actionFeedback(bottomClearance: CGFloat = 16) -> some View {
        modifier(NActionFeedbackBanner(bottomClearance: bottomClearance))
    }
}
