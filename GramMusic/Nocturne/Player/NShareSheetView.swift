import SwiftUI

struct NShareSheetView: View {
    let track: AudioTrack
    var onShare: (() -> Void)? = nil
    @Environment(TelegramService.self) private var telegram
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    
    @Environment(PlayerEngine.self) private var player
    
    @State private var lyrics: Lyrics?
    @State private var selectedLineIndices: Set<Int> = []
    @State private var isSharing: Bool = false
    
    @State private var selectedMode: ShareCardMode = .normal
    @State private var selectedColor: Color = Color(red: 0.8, green: 0.2, blue: 0.4)
    @State private var isEditingLyrics = false
    
    let availableColors: [Color] = [
        Color(red: 0.9, green: 0.2, blue: 0.3), // Red
        Color(red: 0.2, green: 0.6, blue: 0.9), // Blue
        Color(red: 0.3, green: 0.8, blue: 0.4), // Green
        Color(red: 0.6, green: 0.3, blue: 0.9), // Purple
        Color(red: 0.9, green: 0.6, blue: 0.2), // Orange
        Color(red: 0.8, green: 0.2, blue: 0.4), // Pink/Magenta
        Color.black,
        Color(white: 0.2)
    ]
    
    var selectedLines: [LyricLine]? {
        if !selectedLineIndices.isEmpty, let lyrics = lyrics {
            let sortedIndices = selectedLineIndices.sorted().filter { lyrics.displayLines.indices.contains($0) }
            return sortedIndices.map { lyrics.displayLines[$0] }.filter { !$0.text.isEmpty }
        }
        return nil
    }

    @State private var artworkImage: UIImage?

    var body: some View {
        ZStack {
            Color(white: 0.05).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Share")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)

                    
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
                .animation(.easeInOut, value: selectedMode)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 8)
                
                // Preview Carousel
                TabView(selection: $selectedMode) {
                    ZStack {
                        ShareCard(
                            track: track,
                            artworkImage: artworkImage,
                            lyrics: nil,
                            mode: .normal,
                            backgroundColor: selectedColor
                        )
                        .scaleEffect(260.0 / 1080.0)
                        .frame(width: 260, height: 462)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.bottom, 48)
                    .tag(ShareCardMode.normal)
                    
                    if let loadedLyrics = lyrics, !loadedLyrics.displayLines.isEmpty {
                        // Lyrics Mode Preview (Simulating Instagram Story)
                        ZStack {
                            ShareCard(
                                track: track,
                                artworkImage: artworkImage,
                                lyrics: selectedLines ?? Array(loadedLyrics.displayLines.prefix(4)),
                                mode: .lyrics,
                                backgroundColor: selectedColor
                            )
                            .scaleEffect(260.0 / 1080.0)
                            .frame(width: 260, height: 462)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isEditingLyrics = true
                        }
                        .padding(.bottom, 48)
                        .tag(ShareCardMode.lyrics)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(height: 500)
                .padding(.top, 16)
                .overlay(alignment: .bottom) {
                    if let loadedLyrics = lyrics, !loadedLyrics.displayLines.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isEditingLyrics = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if selectedMode == .lyrics {
                                    Image(systemName: "text.quote")
                                    Text(selectedLineIndices.isEmpty ? "Edit" : "Edit (\(selectedLineIndices.count)/4)")
                                } else {
                                    Image(systemName: "clock")
                                    Text(selectedLineIndices.isEmpty ? "Set Starting Lyric" : "Starting Lyric Selected")
                                }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Material.ultraThin, in: Capsule())
                            .environment(\.colorScheme, .dark)
                        }
                        .padding(.bottom, 80)
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }

                
                // Color Picker (only useful/shown if we want to change bg)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(availableColors, id: \.self) { color in
                            Circle()
                                .fill(color)
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: selectedColor == color ? 3 : 0)
                                )
                                .onTapGesture {
                                    withAnimation {
                                        selectedColor = color
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
                .padding(.top, 8)
                
                Spacer()
                
                // Share Targets
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ShareTargetButton(icon: "camera", title: "Instagram", color: Color(red: 0.9, green: 0.2, blue: 0.5)) {
                            share(.instagram)
                        }
                        ShareTargetButton(icon: "square.and.arrow.up", title: "More", color: Color(white: 0.2)) {
                            share(.system)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                }
                .background(Color(white: 0.08))
                .disabled(isSharing)
            }
            
            if isSharing {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Generating...")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(32)
                .background(Color(white: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .task {
            if let data = await telegram.highResArtwork(for: track) ?? track.artworkData {
                artworkImage = UIImage(data: data)
            }
            lyrics = await telegram.lyrics(for: track)
        }
        .sheet(isPresented: $isEditingLyrics) {
            LyricsSelectionSheet(
                lyrics: lyrics,
                selectedLineIndices: $selectedLineIndices,
                maxSelections: selectedMode == .lyrics ? 4 : 1
            )
        }

    }
    
    private func share(_ target: ShareTarget) {
        onShare?()
        let capturedTime = player.currentTime
        isSharing = true
        
        // For lyrics mode, use the first selected lyric's timestamp if available
        let shareLyrics = selectedLines ?? Array(lyrics?.displayLines.prefix(4) ?? [])
        let audioStart: Double
        
        if let firstSelected = selectedLines?.sorted(by: { $0.time ?? 0 < $1.time ?? 0 }).first, let time = firstSelected.time {
            audioStart = time
        } else if selectedMode == .lyrics, let firstLyric = shareLyrics.first, let time = firstLyric.time {
            audioStart = time
        } else {
            audioStart = capturedTime
        }
        
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await ShareService.share(
                track,
                telegram: telegram,
                lyrics: shareLyrics,
                mode: selectedMode,
                backgroundColor: selectedColor,
                target: target,
                audioStartTime: audioStart
            )
            isSharing = false
            dismiss()
        }
    }
}

private struct LyricsSelectionSheet: View {
    let lyrics: Lyrics?
    @Binding var selectedLineIndices: Set<Int>
    var maxSelections: Int = 4
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.1).ignoresSafeArea()
                
                if let lyrics = lyrics, !lyrics.displayLines.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(lyrics.displayLines.enumerated()), id: \.offset) { index, line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .farsiSupport(text: line.text, size: 22, weight: .bold)
                                    .foregroundStyle(selectedLineIndices.contains(index) ? .white : Color(white: 0.3))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        toggleSelection(for: index)
                                    }
                                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedLineIndices)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)
                        .environment(\.layoutDirection, lyrics.displayLines.contains(where: { $0.text.isFarsi }) ? .rightToLeft : .leftToRight)
                    }
                } else {
                    Text("No lyrics available")
                        .foregroundStyle(Color(white: 0.5))
                }
            }
            .navigationTitle(maxSelections == 1 ? "Select Starting Lyric" : "Select Lyrics (Max 4)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    private func toggleSelection(for index: Int) {
        if maxSelections == 1 {
            selectedLineIndices = [index]
            dismiss()
            return
        }
        
        if selectedLineIndices.contains(index) {
            selectedLineIndices.remove(index)
        } else {
            // Keep up to 4 consecutive lines.
            if selectedLineIndices.isEmpty {
                selectedLineIndices.insert(index)
            } else {
                let sorted = selectedLineIndices.sorted()
                // Only allow contiguous selection
                if index == sorted.first! - 1 || index == sorted.last! + 1 {
                    if selectedLineIndices.count < 4 {
                        selectedLineIndices.insert(index)
                    } else {
                        // Max 4 lines reached, drop the furthest one
                        if index < sorted.first! {
                            selectedLineIndices.remove(sorted.last!)
                            selectedLineIndices.insert(index)
                        } else {
                            selectedLineIndices.remove(sorted.first!)
                            selectedLineIndices.insert(index)
                        }
                    }
                } else {
                    // Not contiguous, reset selection
                    selectedLineIndices = [index]
                }
            }
        }
    }
}

private struct ShareTargetButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color)
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}
