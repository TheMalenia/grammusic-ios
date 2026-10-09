import SwiftUI

// The small floating "source" badges shown over the Now Playing artwork — which chat, profile or
// playlist the current track came from. Split out of NNowPlayingView.swift, which had grown past
// 840 lines.

struct FloatingChatBadge: View {
    let chat: TelegramChat
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    @State private var photoData: Data?
    @State private var randomOffsetX: CGFloat = 0
    @State private var randomOffsetY: CGFloat = 0

    /// `@State`, not a stored `let`: a plain property allocates a fresh TimerPublisher on every
    /// re-init of this struct (i.e. every parent body pass), and because the publisher is a class
    /// `onReceive` sees a new identity and tears down / re-schedules the run-loop timer each time.
    @State private var timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: action) {
            Group {
                if chat.kind == .savedMessages {
                    Circle()
                        .fill(theme.accent.fillGradient)
                        .overlay {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                } else if let data = photoData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color(white: 0.15)
                        Image(systemName: chat.kind.symbolName)
                            .foregroundStyle(.white)
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .offset(x: randomOffsetX, y: randomOffsetY)
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 1.5)) {
                randomOffsetX = CGFloat.random(in: -5...5)
                randomOffsetY = CGFloat.random(in: -5...5)
            }
        }
        .task(id: chat.id) {
            if chat.kind != .savedMessages {
                photoData = await telegram.chatPhotoData(for: chat)
            }
        }
    }
}

struct FloatingProfileBadge: View {
    let profile: UserProfilePlaylist
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    @State private var photoData: Data?
    @State private var randomOffsetX: CGFloat = 0
    @State private var randomOffsetY: CGFloat = 0

    /// `@State`, not a stored `let`: a plain property allocates a fresh TimerPublisher on every
    /// re-init of this struct (i.e. every parent body pass), and because the publisher is a class
    /// `onReceive` sees a new identity and tears down / re-schedules the run-loop timer each time.
    @State private var timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: action) {
            Group {
                if let data = photoData ?? profile.photoData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color(white: 0.15)
                        Image(systemName: "person.fill")
                            .foregroundStyle(.white)
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .offset(x: randomOffsetX, y: randomOffsetY)
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 1.5)) {
                randomOffsetX = CGFloat.random(in: -5...5)
                randomOffsetY = CGFloat.random(in: -5...5)
            }
        }
        .task(id: profile.userId) {
            photoData = await telegram.profilePhotoData(for: profile)
        }
    }
}

struct FloatingYourProfileBadge: View {
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var randomOffsetX: CGFloat = 0
    @State private var randomOffsetY: CGFloat = 0

    /// `@State`, not a stored `let`: a plain property allocates a fresh TimerPublisher on every
    /// re-init of this struct (i.e. every parent body pass), and because the publisher is a class
    /// `onReceive` sees a new identity and tears down / re-schedules the run-loop timer each time.
    @State private var timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(theme.accent.fillGradient)
                .overlay {
                    Image(systemName: "music.mic")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .offset(x: randomOffsetX, y: randomOffsetY)
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 1.5)) {
                randomOffsetX = CGFloat.random(in: -5...5)
                randomOffsetY = CGFloat.random(in: -5...5)
            }
        }
    }
}
