import SwiftUI

/// Nocturne login. A Telegram-native flow whose step is driven by `telegram.authState`
/// (phone → code → twofa), rendered on `ScreenBackground()` with a centered logo, display
/// title + subtitle, and a floating full-width Continue pill. `forcePhone` lets the Back
/// chevron return to the phone step even while TDLib still waits for the code/password.
struct NLoginView: View {
    @Environment(\.theme) private var theme
    @Environment(TelegramService.self) private var telegram
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step { case phone, code, twofa }

    @State private var country = Countries.defaultCountry
    @State private var dialCode = Countries.defaultCountry.dialCode
    @State private var number = ""
    @State private var code = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var submittedPhone = ""
    @State private var busy = false
    @State private var showTerms = false
    @State private var showCountryPicker = false
    @State private var resendSeconds = 0
    @State private var resendTimerTask: Task<Void, Never>?
    @State private var isResending = false
    @State private var showSlowHint = false
    @State private var slowHintTask: Task<Void, Never>?
    
    @State private var path: [Step] = []

    @FocusState private var focus: Field?
    @State private var focusTask: Task<Void, Never>?
    private enum Field { case dial, number, code, password }

    // MARK: Derived step

    private var step: Step {
        switch telegram.authState {
        case .waitingForCode: return .code
        case .waitingForPassword: return .twofa
        default: return .phone
        }
    }

    private var codeLength: Int {
        telegram.codeInfo?.length ?? 5
    }

    private var phoneDigits: String { number.filter(\.isNumber) }
    private var fullPhone: String { dialCode + phoneDigits }
    private var displayPhone: String { "\(dialCode) \(number)" }

    private var isValid: Bool {
        switch step {
        case .phone: return phoneDigits.count >= 6
        case .code: return code.count == codeLength
        case .twofa: return password.count >= 1
        }
    }

    private var codeDeliveryMessage: String {
        if let info = telegram.codeInfo {
            if info.isTelegramApp {
                return "We've sent the code to the Telegram app on your other device."
            } else {
                return "We've sent the code via \(info.typeDescription)."
            }
        }
        return "We've sent the code to \(submittedPhone.isEmpty ? "your Telegram" : submittedPhone)."
    }

    // MARK: Body

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                ScreenBackground()
                stepScaffold { phoneStepContent }
            }
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationDestination(for: Step.self) { destStep in
                ZStack {
                    ScreenBackground()
                    stepScaffold {
                        if destStep == .code {
                            codeStepContent
                        } else if destStep == .twofa {
                            twofaStepContent
                        }
                    }
                }
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        IconButton(systemName: "chevron.left") {
                            goBackToPhone()
                        }
                        .accessibilityLabel("Back")
                    }
                }
                .safeAreaInset(edge: .bottom) { bottomBar }
            }
        }
        .sheet(isPresented: $showCountryPicker) { NCountryPicker(selection: $country) }
        .onChange(of: country) { _, c in
            if dialCode != c.dialCode {
                dialCode = c.dialCode
                applyPhoneFormatting()
            }
        }
        .onChange(of: dialCode) { _, v in
            let normalized = v.convertingNonEnglishDigits
            if normalized != dialCode { dialCode = normalized }
            syncCountryFromDial()
            applyPhoneFormatting()
        }
        .onChange(of: number) { _, v in
            let normalized = v.convertingNonEnglishDigits
            if normalized != number { number = normalized }
            applyPhoneFormatting()
        }
        .onChange(of: password) { _, v in
            let converted = v.convertingNonEnglishDigits
            if converted != password { password = converted }
        }
        .onChange(of: telegram.authState) { _, newState in
            telegram.lastError = nil
            // **A submit in flight (`busy`) owns the flow — neither reset below may fire under it.**
            // Entering the demo number (and leaving demo mode for a real one) swaps the backend
            // *inside* `setPhoneNumber`, and a freshly started client announces itself by walking
            // through `.initializing` → `.waitingForPhoneNumber` before it can accept anything.
            // That is indistinguishable from a genuine return to the phone screen, so the first
            // branch wiped `submittedPhone` mid-submit — and the `.waitingForCode` arriving moments
            // later then looked to the second branch like state TDLib had resumed from disk, and
            // was thrown away by `resetAuth()`. The visible result: the first Continue did nothing
            // but dismiss the keyboard, and only the second — by which time the swap had already
            // happened and no longer re-announced — reached the code screen.
            if newState == .waitingForPhoneNumber, !busy {
                path = []
                code = ""
                password = ""
                submittedPhone = ""
                busy = false
                resendTimerTask?.cancel()
                clearFocus()
            } else if submittedPhone.isEmpty, !busy,
                      newState.isWaitingForCode || newState.isWaitingForPassword {
                // If we arrive at code/password but the user never submitted a phone in THIS
                // session, TDLib resumed stale state from disk. Reset TDLib.
                path = []
                Task { await telegram.resetAuth() }
            } else {
                updatePath(for: newState)
                if newState == .ready {
                    clearFocus()
                }
            }
        }
        .onChange(of: code) { _, v in
            let converted = v.convertingNonEnglishDigits
            let digits = String(converted.filter(\.isNumber).prefix(codeLength))
            if digits != code { code = digits }
            if digits.count == codeLength { submit() }
        }
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty {
                clearFocus()
            } else if newPath.count == 1 {
                if newPath.contains(.code) {
                    setFocus(.code, delayMs: 250)
                    startResendTimer(seconds: telegram.codeInfo?.timeout ?? 60)
                } else if newPath.contains(.twofa) {
                    setFocus(.password, delayMs: 250)
                }
            }
        }
        .onAppear {
            if submittedPhone.isEmpty {
                path = []
                code = ""
                password = ""
                busy = false
            }
            updatePath(for: telegram.authState)
        }
    }
    
    private func updatePath(for authState: TelegramAuthState) {
        switch authState {
        case .waitingForCode:
            if !path.contains(.code) {
                path = []
                path.append(Step.code)
                startResendTimer(seconds: authState.codeInfo?.timeout ?? 60)
            }
        case .waitingForPassword:
            if !path.contains(.twofa) {
                path = []
                path.append(Step.twofa)
            }
        default:
            path = []
        }
    }

    /// **The phone step never takes focus by itself.** Arriving at it — a cold launch, the Back
    /// chevron, "Change Phone Number", a remote sign-out — leaves the keyboard down; it comes up
    /// when the user taps the number or the country code, and not before.
    ///
    /// Auto-raising it was also what put the keyboard on top of the Continue pill on the way back
    /// from the code screen: the bottom bar is a `safeAreaInset`, which SwiftUI lifts by the
    /// keyboard's height, but a keyboard frame change *during* the pop never reaches the restored
    /// root, so the bar stayed at the bottom with the keyboard over it. Three separate sites asked
    /// for focus on that one path (the auth state dropping to `waitingForPhoneNumber`, the path
    /// emptying, and the Back button) and the shortest delay won, squarely inside the transition.
    ///
    /// Put the keyboard away *and* drop any focus request still waiting out its delay — otherwise
    /// a pending `.code` focus fires a quarter-second after the user has already left that screen
    /// and re-opens the keyboard on the phone step.
    private func clearFocus() {
        focusTask?.cancel()
        focusTask = nil
        focus = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Only ever one pending focus request: a later one supersedes whatever is still waiting,
    /// rather than both landing and the *shorter* delay deciding when the keyboard appears.
    private func setFocus(_ target: Field, delayMs: Int = 120) {
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            focus = target
        }
    }

    // MARK: Individual Step Contents

    private var phoneStepContent: some View {
        VStack(spacing: 22) {
            LogoTile(size: 66)
            VStack(spacing: 8) {
                Text("Your Phone Number")
                    .font(.display(27, .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                Text("Confirm your country code and enter your phone number to connect your Telegram.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // An unexpected sign-out needs to actually read as an explanation, not a caption —
            // the user didn't ask to be here and will otherwise assume the app broke.
            if step == .phone, let notice = telegram.sessionExpiredNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.accentColor)
                    Text(notice)
                        .font(.system(size: 13.5))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.accentColor.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.accentColor.opacity(0.28), lineWidth: 1)
                )
                .frame(maxWidth: 320)
                .accessibilityElement(children: .combine)
            }

            phoneField

            Link(destination: URL(string: "https://telegram.org/faq#q-how-do-i-register")!) {
                Text("New to Telegram? Learn how to register")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(theme.accentColor)
            }

            if step == .phone, let error = telegram.lastError {
                errorCallout(error)
            }

            slowHint
        }
        .animation(.snappy, value: showSlowHint)
        .animation(.snappy, value: telegram.lastError)
    }

    private var codeStepContent: some View {
        VStack(spacing: 22) {
            LogoTile(size: 66)
            VStack(spacing: 8) {
                Text("Enter Code")
                    .font(.display(27, .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                Text(codeDeliveryMessage)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }

            codeField

            slowHint
        }
        .animation(.snappy, value: telegram.lastError)
    }

    private var twofaStepContent: some View {
        VStack(spacing: 18) {
            LogoTile(size: 58)
            VStack(spacing: 6) {
                Text("Enter Password")
                    .font(.display(26, .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                
                // The hint itself is rendered once, by the card directly above the password
                // field in `twofaField` — where it's actually useful. The header stays the
                // header; showing the hint in both places printed it twice.
                Text("Two-step verification keeps your account secure.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            twofaField

            if step == .twofa, let error = telegram.lastError {
                errorCallout(error)
            }

            slowHint
        }
        .animation(.snappy, value: telegram.lastError)
    }

    // MARK: Phone

    private var phoneField: some View {
        VStack(spacing: 12) {
            Button { showCountryPicker = true } label: {
                HStack(spacing: 10) {
                    Text(country.flag).font(.title3)
                    Text(country.name).font(.system(size: 16)).foregroundStyle(theme.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text3)
                }
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(fieldBackground)
            }
            .buttonStyle(NPressable(scale: 0.98))

            HStack(spacing: 0) {
                TextField("+1", text: $dialCode)
                    .keyboardType(.asciiCapableNumberPad)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.text)
                    .frame(width: 64)
                    .focused($focus, equals: .dial)
                    .multilineTextAlignment(.center)
                Divider().frame(height: 24)
                TextField("", text: phoneEntry)
                    .keyboardType(.asciiCapableNumberPad)
                    .textContentType(.telephoneNumber)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.text)
                    .focused($focus, equals: .number)
                    // The field is never *really* empty (see `phoneEntry`), so it would never show
                    // a `TextField` placeholder. This one keys off the number the user can see.
                    .overlay(alignment: .leading) {
                        if number.isEmpty {
                            Text("Phone number")
                                .font(.system(size: 16))
                                .foregroundStyle(theme.text3)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.leading, 12)
                    .onChange(of: number) { _, _ in
                        applyPhoneFormatting()
                    }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(fieldBackground)
        }
    }

    /// A zero-width space kept in front of the phone number *in the text field only*.
    ///
    /// It is how backspace-on-empty becomes observable. `UITextField` reports nothing when delete
    /// is pressed with no text to delete, and SwiftUI surfaces no key events for the number pad —
    /// so the only signal is a character that gets eaten. With the sentinel there, the first delete
    /// past the last digit produces a change to an *empty* string, and that can only mean the user
    /// asked to go back past the start of the number. It never reaches `number`, so nothing
    /// downstream (formatting, `fullPhone`, validation) ever sees it.
    private static let phoneSentinel = "\u{200B}"

    private var phoneEntry: Binding<String> {
        Binding(
            get: { Self.phoneSentinel + number },
            set: { entered in
                guard entered.hasPrefix(Self.phoneSentinel) else {
                    if entered.isEmpty {
                        // Delete with an empty number: step back to the country code, the way the
                        // hardware Back arrow would. `number` is untouched, so the getter puts the
                        // sentinel straight back.
                        focus = .dial
                    } else {
                        // The sentinel is gone but text arrived — autofill or a paste replaced the
                        // whole field rather than editing it. Take it as the number.
                        number = entered
                    }
                    return
                }
                number = String(entered.dropFirst(Self.phoneSentinel.count))
            }
        )
    }

    private func applyPhoneFormatting() {
        let formatted = PhoneNumberFormatter.format(nationalNumber: number, dialCode: dialCode)
        if formatted != number {
            number = formatted
        }
    }

    // MARK: Code (dynamic digit cells + hidden field)

    private var codeField: some View {
        VStack(spacing: 16) {
            ZStack {
                // Hidden field captures the digits.
                TextField("", text: $code)
                    .keyboardType(.asciiCapableNumberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focus, equals: .code)
                    .foregroundStyle(.clear)
                    .accentColor(.clear)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)

                HStack(spacing: 8) {
                    ForEach(0..<codeLength, id: \.self) { i in codeCell(i) }
                }
                .contentShape(Rectangle())
                .onTapGesture { focus = .code }
            }

            if step == .code, let error = telegram.lastError {
                errorCallout(error)
            }

            if isResending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sending a new code…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
            } else if resendSeconds > 0 {
                Text("Resend code in 0:\(String(format: "%02d", resendSeconds))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.text2)
            } else {
                Button {
                    resendCode()
                } label: {
                    Text("Resend code")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func startResendTimer(seconds: Int = 60) {
        resendTimerTask?.cancel()
        resendSeconds = max(seconds, 0)
        guard resendSeconds > 0 else { return }
        
        resendTimerTask = Task { @MainActor in
            while resendSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                resendSeconds -= 1
            }
        }
    }

    /// Re-request the code. The cooldown starts on **success**, not on the tap: starting it first
    /// meant a request lost to a bad link locked the user out of retrying for a full minute with
    /// nothing to show for it. A failure leaves the button live so they can simply try again.
    private func resendCode() {
        guard !isResending else { return }
        Task { @MainActor in
            isResending = true
            telegram.lastError = nil
            defer { isResending = false }
            let ok = await telegram.setPhoneNumber(fullPhone)
            if ok {
                startResendTimer(seconds: telegram.codeInfo?.timeout ?? 60)
            }
        }
    }

    private func codeCell(_ i: Int) -> some View {
        let chars = Array(code)
        let filled = i < chars.count
        let active = i == chars.count
        let cellWidth: CGFloat = codeLength > 5 ? 44 : 50
        
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(theme.elev)
            .frame(width: cellWidth, height: 60)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(active ? theme.accentColor : theme.hairline,
                                  lineWidth: active ? 2 : 0.5)
            }
            .overlay {
                if filled {
                    Text(String(chars[i]))
                        .font(.display(24, .semibold))
                        .foregroundStyle(theme.text)
                }
            }
    }

    // MARK: 2FA

    private var twofaField: some View {
        VStack(spacing: 12) {
            // Password Hint Card
            if let hint = telegram.passwordHint, !hint.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                    Text("Hint: \(hint)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.text)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.elev)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
                )
            }

            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.text3)
                
                if isPasswordVisible {
                    TextField("Password", text: $password)
                        .keyboardType(.asciiCapable)
                        .textContentType(.password)
                        .font(.system(size: 16))
                        .foregroundStyle(theme.text)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                } else {
                    SecureField("Password", text: $password)
                        .keyboardType(.asciiCapable)
                        .textContentType(.password)
                        .font(.system(size: 16))
                        .foregroundStyle(theme.text)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                }
                
                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.text3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(fieldBackground)
        }
    }

    /// A failure the user has to read and act on, rendered as a callout rather than a bare red
    /// line. It is always placed with the field it belongs to — a wrong code reads as a caption
    /// of the digit cells — never flush against the floating Continue pill, where it looked like
    /// a label on the button.
    private func errorCallout(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red.opacity(0.28), lineWidth: 1)
        )
        .frame(maxWidth: 320)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(theme.elev)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            }
    }

    // MARK: Floating Continue pill

    private var continueButton: some View {
        Button(action: submit) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(isValid ? theme.accentText : theme.text)
                } else {
                    Text(continueLabel)
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.1)
                        .contentTransition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(isValid ? theme.accentText : theme.text.opacity(0.5))
            .background {
                if isValid {
                    Capsule().fill(theme.brandFill)
                } else {
                    Capsule().fill(theme.scheme == .dark
                        ? Color.white.opacity(0.12)
                        : Color(red: 20/255, green: 20/255, blue: 30/255).opacity(0.06))
                }
            }
            .shadow(color: isValid ? theme.accentColor.opacity(0.35) : .clear, radius: 16, y: 8)
        }
        .buttonStyle(NPressable(scale: 0.97))
        .disabled(!isValid || busy)
        .animation(reduceMotion ? nil : .snappy, value: isValid)
    }

    /// Centres a step when it fits and scrolls it when it doesn't.
    ///
    /// This is the keyboard fix. The steps used to be a `Spacer`-centred `VStack`: once the
    /// keyboard claims the bottom half of the safe area, that stack is asked to lay out a card
    /// taller than the space left, the spacers collapse, and the overflow is simply unreachable —
    /// which is how "Change Phone Number" ended up under the keyboard with no way to get at it.
    /// A scroll view keeps the identical centred look while there's room and stays reachable
    /// when there isn't; `.basedOnSize` means it doesn't bounce when nothing is clipped.
    private func stepScaffold<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // Built up front: `GeometryReader`'s closure escapes, so the non-escaping builder can't be
        // called inside it.
        let stepView = content()
        return GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) { stepView }
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// Pinned above the keyboard by `safeAreaInset`, so both the primary action *and* the escape
    /// hatch out of a mistyped number are always tappable — no scrolling, no dismissing the
    /// keyboard first.
    /// Consent to the Terms of Use, stated where the user acts on it.
    ///
    /// App Review guideline 1.2 wants the agreement presented *before* signing in, and this is the
    /// screen where signing in happens. Tapping the link opens the bundled text (`NTermsSheet`),
    /// which cannot fail to load; `submit()` stamps the accepted version when they continue.
    private var termsConsent: some View {
        VStack(spacing: 2) {
            Text("By continuing you agree to our")
                .foregroundStyle(theme.text.opacity(0.55))
            Button { showTerms = true } label: {
                Text("Terms of Use")
                    .underline()
                    .foregroundStyle(theme.accentColor)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12.5))
        .multilineTextAlignment(.center)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("By continuing you agree to our Terms of Use. Double tap to read them.")
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            continueButton
            if step == .phone { termsConsent }
            if step != .phone {
                Button(action: goBackToPhone) {
                    Text("Change Phone Number")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NPressable(scale: 0.97))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background {
            LinearGradient(colors: [theme.bg.opacity(0), theme.bg.opacity(0.85), theme.bg.opacity(0.95)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        .animation(.snappy, value: step)
        .sheet(isPresented: $showTerms) { NTermsSheet() }
    }

    private var continueLabel: String {
        switch step {
        case .twofa: return "Sign in"
        default: return "Continue"
        }
    }

    // MARK: Actions

    private func submit() {
        guard isValid, !busy else { return }

        // Deliberately no "you're offline" bail here any more. `connectionState` is `.connecting`
        // for the first seconds of every cold launch, so that check refused perfectly good taps
        // and told the user the network was down when it wasn't. The service now waits for the
        // link, then retries transient failures — so we hold the spinner instead of flashing red.
        Task {
            busy = true
            telegram.lastError = nil
            startSlowHint()
            defer { stopSlowHint(); busy = false }

            switch step {
            case .phone:
                // The consent line sits directly above the button they just pressed, so this is
                // the moment agreement is given. Recorded as a version so revised terms re-present.
                StorageKeys.recordTermsAcceptance()
                submittedPhone = displayPhone
                telegram.sessionExpiredNotice = nil
                await telegram.setPhoneNumber(fullPhone)
            case .code:
                await telegram.checkCode(code)
                if telegram.lastError != nil { code = "" }
            case .twofa:
                await telegram.checkPassword(password)
            }
        }
    }

    /// After a few seconds of waiting, say *why* we're still spinning. Without this a retry that
    /// works looks identical to a hang.
    private func startSlowHint() {
        slowHintTask?.cancel()
        showSlowHint = false
        slowHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            showSlowHint = true
        }
    }

    private func stopSlowHint() {
        slowHintTask?.cancel()
        slowHintTask = nil
        showSlowHint = false
    }

    @ViewBuilder
    private var slowHint: some View {
        if showSlowHint {
            Text(telegram.isOffline
                 ? "Still connecting to Telegram — check your internet or VPN."
                 : "Still working — the connection is slow right now.")
                .font(.system(size: 13))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }

    private func goBackToPhone() {
        clearFocus()
        resendTimerTask?.cancel()
        stopSlowHint()
        isResending = false
        path = []
        code = ""
        password = ""
        busy = false
        Task { await telegram.resetAuth() }
        // No `setFocus` here, deliberately: the phone step opens with the keyboard down.
    }

    private func syncCountryFromDial() {
        let digits = dialCode.filter(\.isNumber)
        let normalized = "+" + digits
        if normalized != dialCode { dialCode = normalized; return }
        if let match = Countries.country(forDialCode: normalized), match != country { country = match }
    }
}

private extension String {
    /// Converts Eastern Arabic (Arabic-Indic) and Persian numerals to Western ASCII (0-9).
    var convertingNonEnglishDigits: String {
        let mappings: [Character: Character] = [
            "۰": "0", "۱": "1", "۲": "2", "۳": "3", "۴": "4",
            "۵": "5", "۶": "6", "۷": "7", "۸": "8", "۹": "9",
            "٠": "0", "١": "1", "٢": "2", "٣": "3", "٤": "4",
            "٥": "5", "٦": "6", "٧": "7", "٨": "8", "٩": "9"
        ]
        return String(map { mappings[$0] ?? $0 })
    }
}
