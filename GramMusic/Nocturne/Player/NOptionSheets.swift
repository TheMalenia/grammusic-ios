import SwiftUI
import AVKit

// Small option sheets (screens §12 "Option sheets"). Each renders a checkmarked list;
// the call site supplies `.presentationDetents([.height(…)])`.

/// A reusable row used by the option sheets: title + trailing checkmark on the active value.
private struct NOptionRow: View {
    @Environment(\.theme) private var theme
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: selected ? .semibold : .regular))
                    .foregroundStyle(theme.text)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shared sheet shell: title, X close, and a list of option rows on the screen backdrop.
private struct NOptionSheet<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            List {
                content
                    .listRowBackground(theme.elev)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ScreenBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.text2)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationBackground(theme.bg)
    }
}

// MARK: - Sleep timer

/// Off / 5 / 15 / 30 / 45 min / End of track → `player.setSleepTimer(minutes:)`.
/// "End of track" is modeled by scheduling for the remaining time of the current track.
struct NSleepSheet: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    /// Minute presets; `nil` = Off, `-1` = End of track (sentinel handled below).
    private let options: [(label: String, minutes: Int?)] = [
        ("Off", nil),
        ("5 minutes", 5),
        ("15 minutes", 15),
        ("30 minutes", 30),
        ("45 minutes", 45),
        ("End of track", -1),
    ]

    var body: some View {
        NOptionSheet(title: "Sleep Timer") {
            ForEach(options, id: \.label) { option in
                NOptionRow(title: option.label, selected: isSelected(option.minutes)) {
                    apply(option.minutes)
                    dismiss()
                }
            }
        }
    }

    private var isOff: Bool { player.sleepTimerEnd == nil }

    private func isSelected(_ minutes: Int?) -> Bool {
        // We can only reliably reflect Off; a running timer just shows no preset checked
        // beyond Off being unchecked. Off is selected when no timer is set.
        minutes == nil ? isOff : false
    }

    private func apply(_ minutes: Int?) {
        switch minutes {
        case .none:
            player.setSleepTimer(minutes: nil)
        case .some(-1):
            // End of track: schedule for the time remaining on the current track.
            let remaining = max(player.duration - player.currentTime, 0)
            player.setSleepTimer(minutes: max(Int((remaining / 60).rounded(.up)), 1))
        case .some(let m):
            player.setSleepTimer(minutes: m)
        }
    }
}

// MARK: - Playback speed

/// 0.5 / 0.75 / Normal / 1.25 / 1.5 / 2× → `player.playbackRate`.
struct NSpeedSheet: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    private let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        NOptionSheet(title: "Playback Speed") {
            ForEach(rates, id: \.self) { rate in
                NOptionRow(title: label(for: rate),
                           selected: player.playbackRate == rate) {
                    player.playbackRate = rate
                    dismiss()
                }
            }
        }
    }

    private func label(for rate: Float) -> String {
        rate == 1.0 ? "Normal" : "\(rate.formatted())×"
    }
}

// MARK: - AirPlay & devices

/// Hosts the real system route picker. The call site sizes it via presentation detents.
struct NAirPlaySheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Choose an output device for playback.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                NRoutePicker(tint: theme.text, activeTint: theme.accentColor)
                    .frame(width: 64, height: 64)
                Spacer(minLength: 0)
            }
            .padding(.top, 28)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ScreenBackground())
            .navigationTitle("AirPlay & Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.text2)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationBackground(theme.bg)
    }
}

/// Shared `AVRoutePickerView` wrapper (also used inline by Now Playing's secondary row).
struct NRoutePicker: UIViewRepresentable {
    var tint: Color = .white
    var activeTint: Color = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(activeTint)
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(tint)
        uiView.activeTintColor = UIColor(activeTint)
    }
}

/// A sheet to walk through Telegram's dynamic reporting flow.
struct NReportSheet: View {
    let chatId: Int64
    let messageIds: [Int64]?
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram

    @State private var options: [TelegramReportOption]?
    @State private var selectedOptionId: Data?
    @State private var textRequired = false
    @State private var reportText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var success = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground().ignoresSafeArea()
                
                VStack(spacing: 0) {
                    if success {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(Color(hex: 0x34C759))
                            Text("Report Submitted")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(theme.text)
                            Text("Thank you for your report.")
                                .font(.system(size: 15))
                                .foregroundStyle(theme.text2)
                                .multilineTextAlignment(.center)
                            
                            Button("Done") {
                                onDismiss()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accentColor)
                            .padding(.top, 24)
                        }
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if textRequired {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Additional details")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(theme.text)
                            
                            TextField("Reason...", text: $reportText, axis: .vertical)
                                .lineLimit(3...6)
                                .padding(12)
                                .background(theme.elev)
                                .cornerRadius(8)
                                .foregroundStyle(theme.text)
                            
                            Button(action: {
                                Task { await submit(optionId: selectedOptionId, text: reportText) }
                            }) {
                                HStack {
                                    Spacer()
                                    if isLoading {
                                        ProgressView().tint(.white)
                                    } else {
                                        Text("Submit")
                                            .font(.system(size: 16, weight: .semibold))
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 14)
                                .background(reportText.isEmpty || isLoading ? theme.elev : theme.accentColor)
                                .foregroundStyle(reportText.isEmpty || isLoading ? theme.text2 : .white)
                                .cornerRadius(12)
                            }
                            .disabled(reportText.isEmpty || isLoading)
                            
                            Spacer()
                        }
                        .padding(20)
                    } else if let options = options {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(options, id: \.id) { option in
                                    Button(action: {
                                        Task { await submit(optionId: option.id, text: nil) }
                                    }) {
                                        HStack {
                                            Text(option.text)
                                                .font(.system(size: 16))
                                                .foregroundStyle(theme.text)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(theme.text2)
                                        }
                                        .padding(.vertical, 16)
                                        .padding(.horizontal, 20)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isLoading)
                                    
                                    if option.id != options.last?.id {
                                        Divider().overlay(theme.hairline).padding(.leading, 20)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    } else if errorMessage == nil {
                        VStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                    
                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: 0xFF453A))
                            .padding()
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { onDismiss() }
                        .labelStyle(.iconOnly)
                }
            }
            .onAppear {
                if options == nil && !textRequired && !success {
                    Task { await submit(optionId: nil, text: nil) }
                }
            }
        }
    }
    
    private func submit(optionId: Data?, text: String?) async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await telegram.reportChat(chatId: chatId, messageIds: messageIds, optionId: optionId, text: text)
            switch result {
            case .ok:
                success = true
            case .optionRequired(_, let newOptions):
                self.options = newOptions
                self.textRequired = false
            case .textRequired(let newOptionId, _):
                self.selectedOptionId = newOptionId
                self.options = nil
                self.textRequired = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
