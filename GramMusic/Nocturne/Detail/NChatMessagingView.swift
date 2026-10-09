import SwiftUI

struct NChatMessagingView: View {
    let chat: TelegramChat
    @State private var controller: ChatMessagingController
    @State private var inputText = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(PlayerEngine.self) private var player
    @Environment(TelegramService.self) private var telegram
    
    init(chat: TelegramChat, telegram: TelegramService) {
        self.chat = chat
        self._controller = State(initialValue: ChatMessagingController(chatId: chat.id, telegram: telegram))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().background(theme.hairline)
            
            messageList
            
            if controller.canSendMessages {
                VStack(spacing: 0) {
                    inlineBotDropdown
                    inputBar
                }
            }
        }
        .nMiniPlayerClearance(player.current != nil, offline: telegram.isOfflineStable)
        .modifier(NScrollDockViewport())
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipe()
        .task {
            await controller.start()
        }
        .onDisappear {
            controller.stop()
        }
    }
    
    @ViewBuilder
    private var messageList: some View {
        if controller.isLoading && controller.messages.isEmpty {
            VStack {
                Spacer()
                ProgressView()
                    .scaleEffect(1.5)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ScreenBackground())
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if controller.nextFromId != nil && !controller.messages.isEmpty {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task { await controller.loadMore() }
                                }
                        }
                        
                        ForEach(controller.messages.reversed()) { message in
                            MessageRow(message: message, controller: controller, theme: theme)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .background(ScreenBackground())
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: controller.messages.count) {
                    if let first = controller.messages.first {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            proxy.scrollTo(first.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
    
    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NPressable(scale: 0.9))
            
            NChatAvatar(chat: chat, size: 38)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                Text(chat.kindLabel).font(.system(size: 12)).foregroundStyle(theme.text2)
            }
            
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(theme.bg)
    }
    
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(theme.elev)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .foregroundStyle(theme.text)
                .font(.system(size: 16))
            
            Button {
                let text = inputText
                inputText = ""
                Task {
                    await controller.send(text: text)
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? theme.text2 : theme.accentColor)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.bg)
        .onChange(of: inputText) {
            controller.handleInputTextChanged(inputText)
        }
    }
    
    @ViewBuilder
    private var inlineBotDropdown: some View {
        if controller.isInlineQueryLoading || !controller.inlineResults.isEmpty {
            VStack(spacing: 0) {
                Divider().background(theme.hairline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        if controller.isInlineQueryLoading && controller.inlineResults.isEmpty {
                            ProgressView()
                                .padding()
                        } else {
                            ForEach(controller.inlineResults) { result in
                                Button {
                                    Task {
                                        await controller.sendInlineResult(result)
                                        inputText = ""
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let title = result.title {
                                            Text(title)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(theme.text)
                                                .lineLimit(1)
                                        }
                                        if let desc = result.description {
                                            Text(desc)
                                                .font(.system(size: 12))
                                                .foregroundStyle(theme.text2)
                                                .lineLimit(2)
                                        } else {
                                            Text(result.type.capitalized)
                                                .font(.system(size: 12))
                                                .foregroundStyle(theme.accentColor)
                                        }
                                    }
                                    .frame(width: 120, height: 60, alignment: .topLeading)
                                    .padding(8)
                                    .background(theme.elev)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(NPressable(scale: 0.95))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(theme.bg)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: controller.inlineResults.isEmpty)
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let controller: ChatMessagingController
    let theme: AppTheme
    @Environment(PlayerEngine.self) private var player
    
    var body: some View {
        let isMe = message.senderId == 0 // Rough heuristic, proper implementation needs currentUserId
        
        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
            HStack {
                if isMe { Spacer() }
                
                VStack(alignment: .leading, spacing: 4) {
                    contentView
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(isMe ? theme.accentColor.opacity(0.15) : theme.elev)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(isMe ? theme.accentColor.opacity(0.3) : theme.hairline, lineWidth: 1)
                        )
                        .foregroundStyle(theme.text)
                    
                    if let markup = message.replyMarkup {
                        ReplyMarkupView(markup: markup, messageId: message.id, controller: controller, theme: theme)
                    }
                }
                
                if !isMe { Spacer() }
            }
            
            Text(message.date, format: .dateTime.hour().minute())
                .font(.system(size: 11))
                .foregroundStyle(theme.text2)
                .padding(.horizontal, 4)
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        switch message.content {
        case .text(let text):
            Text(text).font(.system(size: 16))
        case .audio(let track, let caption):
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    player.playSingle(track)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.system(size: 24))
                            .foregroundStyle(theme.accentColor)
                            .frame(width: 48, height: 48)
                            .background(theme.bg)
                            .clipShape(Circle())
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayTitle)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(theme.text)
                            Text(track.displaySubtitle)
                                .font(.system(size: 14))
                                .foregroundStyle(theme.text2)
                        }
                    }
                }
                .buttonStyle(NPressable(scale: 0.95))
                
                if let caption = caption {
                    Text(caption).font(.system(size: 16))
                }
            }
        case .unsupported:
            Text("Unsupported message").font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text2)
        }
    }
}

private struct ReplyMarkupView: View {
    let markup: ReplyMarkup
    let messageId: Int64
    let controller: ChatMessagingController
    let theme: AppTheme
    
    @State private var processingButton: String?
    
    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(0..<markup.rows.count), id: \.self) { r in
                let row = markup.rows[r]
                HStack(spacing: 8) {
                    ForEach(Array(0..<row.count), id: \.self) { c in
                        let btn = row[c]
                        let isProcessing = processingButton == btn.text
                        Button {
                            if processingButton != nil { return }
                            processingButton = btn.text
                            Task {
                                await controller.tapInlineButton(messageId: messageId, button: btn)
                                processingButton = nil
                            }
                        } label: {
                            Group {
                                if isProcessing {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Text(btn.text)
                                        .font(.system(size: 14, weight: .medium))
                                }
                            }
                                .foregroundStyle(theme.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(theme.bg)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .opacity(isProcessing ? 0.7 : 1.0)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(theme.hairline, lineWidth: 1)
                                )
                        }
                        .buttonStyle(NPressable(scale: 0.95))
                    }
                }
            }
        }
        .frame(maxWidth: 260)
    }
}

/// Wrapper to easily inject the environment TelegramService when routing.
struct BotMessagingWrapper: View {
    let chat: TelegramChat
    @Environment(TelegramService.self) private var telegram
    var body: some View {
        NChatMessagingView(chat: chat, telegram: telegram)
    }
}
