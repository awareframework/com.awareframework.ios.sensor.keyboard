import UIKit

/// Base class for a custom keyboard extension that records keystrokes to the App Group
/// shared UserDefaults, where KeyboardSensor can pick them up.
///
/// Usage in your Keyboard Extension target:
///
///   class KeyboardViewController: KeyboardInputViewController {
///       override func viewDidLoad() {
///           appGroupIdentifier = "group.com.yourorganization.aware"
///           super.viewDidLoad()
///       }
///   }
///
/// The extension target must have the App Groups entitlement configured with the same
/// identifier as KeyboardSensor.Config.appGroupIdentifier.
open class KeyboardInputViewController: UIInputViewController, UIInputViewAudioFeedback {

    /// App Group identifier. Set this before calling super.viewDidLoad().
    public var appGroupIdentifier: String = ""

    private enum Mode { case letter, number, symbol }
    private var mode: Mode = .letter
    private var isShifted = false
    private var isCapsLocked = false
    private var lastShiftTapTime: TimeInterval = 0
    private let capsLockDoubleTapInterval: TimeInterval = 0.4

    private var keyboardContainer: UIView?
    private var letterButtons: [UIButton] = []
    private weak var shiftButton: UIButton?
    private var deleteInitialTimer: Timer?
    private var deleteRepeatTimer: Timer?
    private var isDeleteLongPressActive = false

    // Suggestion bar
    private let suggestionBar = SuggestionBarView()
    private let textChecker = UITextChecker()
    private weak var globeButton: UIButton?

    // Performance: cached UserDefaults and background queues
    private var cachedDefaults: UserDefaults?
    private let recordingQueue = DispatchQueue(label: "com.awareframework.keyboard.recording", qos: .utility)
    private let suggestionQueue = DispatchQueue(label: "com.awareframework.keyboard.suggestion", qos: .userInitiated)
    private let backgroundTextChecker = UITextChecker()

    // MARK: - Layout constants

    private let keyboardHeight: CGFloat = 260
    private let suggestionBarHeight: CGFloat = 40
    private let rowSpacing: CGFloat = 8
    private let keySpacing: CGFloat = 6
    private let horizontalPadding: CGFloat = 3
    private let verticalPadding: CGFloat = 8
    private let cornerRadius: CGFloat = 5

    private let letterKeyFont = UIFont.systemFont(ofSize: 17)
    private let actionKeyFont = UIFont.systemFont(ofSize: 15)
    private let deleteInitialRepeatDelay: TimeInterval = 0.45
    private let deleteRepeatInterval: TimeInterval = 0.08
    private let keyPressAnimationDuration: TimeInterval = 0.06
    private let keyReleaseAnimationDuration: TimeInterval = 0.12
    private let keyPressedScale: CGFloat = 0.94

    private let keyBackground = UIColor.white
    private let actionKeyBackground = UIColor(white: 0.68, alpha: 1)
    private let boardBackground = UIColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1)

    // MARK: - Key definitions

    private let letterRows: [[String]] = [
        ["q","w","e","r","t","y","u","i","o","p"],
        ["a","s","d","f","g","h","j","k","l"],
        ["⇧","z","x","c","v","b","n","m","⌫"],
    ]

    private let numberRows: [[String]] = [
        ["1","2","3","4","5","6","7","8","9","0"],
        ["-","/",":",";","(",")","$","&","@","\""],
        ["#+=",".",",","?","!","'","⌫"],
    ]

    private let symbolRows: [[String]] = [
        ["[","]","{","}","#","%","^","*","+","="],
        ["_","\\","|","~","<",">","€","£","¥","•"],
        ["123",".",",","?","!","'","⌫"],
    ]

    // MARK: - UIInputViewController

    open var enableInputClicksWhenVisible: Bool {
        true
    }

    open override func viewDidLoad() {
        super.viewDidLoad()

        if !appGroupIdentifier.isEmpty {
            cachedDefaults = UserDefaults(suiteName: appGroupIdentifier)
        }

        // Height — set once with priority 999 to avoid conflict with system encapsulated layout
        let h = view.heightAnchor.constraint(equalToConstant: keyboardHeight + suggestionBarHeight)
        h.priority = UILayoutPriority(999)
        h.isActive = true

        // Suggestion bar — constraints set here, not in buildKeyboard()
        suggestionBar.translatesAutoresizingMaskIntoConstraints = false
        suggestionBar.onSelect = { [weak self] word in self?.applySuggestion(word) }
        view.addSubview(suggestionBar)
        NSLayoutConstraint.activate([
            suggestionBar.topAnchor.constraint(equalTo: view.topAnchor),
            suggestionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            suggestionBar.heightAnchor.constraint(equalToConstant: suggestionBarHeight),
        ])

        // Record that full access was granted so the host app can detect it
        if hasFullAccess,
           !appGroupIdentifier.isEmpty,
           let defaults = UserDefaults(suiteName: appGroupIdentifier) {
            defaults.set(Date().timeIntervalSince1970, forKey: KeyboardSharedKeys.lastFullAccessDate)
            defaults.synchronize()
        }

        buildKeyboard()
    }

    // needsInputModeSwitchKey is only valid after the host connection is established,
    // so update the globe button visibility here instead of at build time.
    open override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globeButton?.isHidden = !needsInputModeSwitchKey
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRepeatingDelete()
    }

    // MARK: - Keyboard construction

    private func buildKeyboard() {
        stopRepeatingDelete()
        keyboardContainer?.removeFromSuperview()
        letterButtons.removeAll()
        shiftButton = nil

        view.backgroundColor = boardBackground

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        keyboardContainer = container

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: suggestionBar.bottomAnchor, constant: verticalPadding),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -verticalPadding),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: horizontalPadding),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -horizontalPadding),
        ])

        let mainStack = UIStackView()
        mainStack.axis = .vertical
        mainStack.spacing = rowSpacing
        mainStack.distribution = .fillEqually
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let contentRows: [[String]]
        switch mode {
        case .letter:  contentRows = letterRows
        case .number:  contentRows = numberRows
        case .symbol:  contentRows = symbolRows
        }

        for row in contentRows {
            mainStack.addArrangedSubview(makeEqualRow(keys: row))
        }
        mainStack.addArrangedSubview(makeBottomRow())
    }

    /// Returns a row where every key has the same width.
    private func makeEqualRow(keys: [String]) -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = keySpacing
        stack.distribution = .fillEqually

        for key in keys {
            let btn = makeKeyButton(key)
            if mode == .letter && key.count == 1 && key != "⇧" && key != "⌫" {
                letterButtons.append(btn)
            }
            if mode == .letter && key == "⇧" {
                shiftButton = btn
            }
            stack.addArrangedSubview(btn)
        }
        return stack
    }

    /// Returns the bottom row: [mode-switch] [space] [return], with proportional widths.
    private func makeBottomRow() -> UIView {
        let switchKey: String
        let switchDisplay: String
        switch mode {
        case .letter:
            switchKey = "MODE_NUM"
            switchDisplay = "123"
        case .number, .symbol:
            switchKey = "MODE_LETTER"
            switchDisplay = "ABC"
        }

        let switchBtn = makeKeyButton(switchKey, display: switchDisplay)
        let spaceBtn  = makeKeyButton("SPACE",  display: "space")
        let returnBtn = makeKeyButton("RETURN", display: "return")

        // Always create the globe button; visibility is updated in viewWillLayoutSubviews
        let globeBtn = makeKeyButton("GLOBE", display: "🌐")
        globeBtn.isHidden = true   // hidden until viewWillLayoutSubviews confirms it's needed
        globeButton = globeBtn

        let container = UIView()
        let allButtons: [UIButton] = [switchBtn, globeBtn, spaceBtn, returnBtn]

        allButtons.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        // Switch key: 15%
        NSLayoutConstraint.activate([
            switchBtn.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            switchBtn.topAnchor.constraint(equalTo: container.topAnchor),
            switchBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            switchBtn.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.15),
        ])

        // Globe key: 12% — always constrained, visibility toggled in viewWillLayoutSubviews
        NSLayoutConstraint.activate([
            globeBtn.leadingAnchor.constraint(equalTo: switchBtn.trailingAnchor, constant: keySpacing),
            globeBtn.topAnchor.constraint(equalTo: container.topAnchor),
            globeBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            globeBtn.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.12),
        ])

        // Return key: 22%
        NSLayoutConstraint.activate([
            returnBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            returnBtn.topAnchor.constraint(equalTo: container.topAnchor),
            returnBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            returnBtn.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.22),
        ])

        // Space bar fills the middle (leading shifts depending on globe visibility via UIStackView isn't
        // used here, so space just pins to globe's trailing — hidden globe still occupies its constraint width,
        // which is acceptable for a research keyboard; use .isHidden = true rather than removing)
        NSLayoutConstraint.activate([
            spaceBtn.leadingAnchor.constraint(equalTo: globeBtn.trailingAnchor, constant: keySpacing),
            spaceBtn.trailingAnchor.constraint(equalTo: returnBtn.leadingAnchor, constant: -keySpacing),
            spaceBtn.topAnchor.constraint(equalTo: container.topAnchor),
            spaceBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    // MARK: - Button factory

    private func makeKeyButton(_ key: String, display: String? = nil) -> UIButton {
        let isAction = isActionKey(key)
        let title = display ?? displayTitle(for: key)

        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = key
        button.backgroundColor = isAction ? actionKeyBackground : keyBackground
        button.setTitleColor(.black, for: .normal)
        button.titleLabel?.font = isAction ? actionKeyFont : letterKeyFont
        button.layer.cornerRadius = cornerRadius
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowOpacity = 0.3
        button.layer.shadowRadius = 0
        button.clipsToBounds = false
        button.addTarget(self, action: #selector(keyTouchDown(_:)), for: .touchDown)
        button.addTarget(
            self,
            action: #selector(keyTouchEnded(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
        if key == "⌫" {
            button.addTarget(self, action: #selector(deleteTouchDown(_:)), for: .touchDown)
            button.addTarget(
                self,
                action: #selector(deleteTouchEnded(_:)),
                for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
            )
        } else {
            button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        }
        return button
    }

    private func displayTitle(for key: String) -> String {
        switch key {
        case "⇧": return "⇧"
        case "⌫": return "⌫"
        default:
            if key.count == 1 {
                return (mode == .letter && isShifted) ? key.uppercased() : key
            }
            return key
        }
    }

    private func isActionKey(_ key: String) -> Bool {
        switch key {
        case "⇧", "⌫", "MODE_NUM", "MODE_LETTER", "#+=", "123",
             "SPACE", "RETURN", "GLOBE":
            return true
        default:
            return false
        }
    }

    // MARK: - Key press handling

    @objc private func keyTapped(_ sender: UIButton) {
        let key = sender.accessibilityIdentifier ?? sender.currentTitle ?? ""
        playKeyboardClick()
        let proxy = textDocumentProxy
        let isPassword = proxy.isSecureTextEntry ?? false
        let before = isPassword ? "" : (proxy.documentContextBeforeInput ?? "")

        switch key {
        case "⌫":
            deleteBackwardAndRecord()

        case "⇧":
            let now = Date().timeIntervalSince1970
            if isCapsLocked {
                isCapsLocked = false
                isShifted = false
                lastShiftTapTime = 0
            } else if isShifted && (now - lastShiftTapTime < capsLockDoubleTapInterval) {
                isCapsLocked = true
                lastShiftTapTime = 0
            } else {
                isShifted.toggle()
                lastShiftTapTime = isShifted ? now : 0
            }
            updateLetterButtonTitles()
            updateShiftButton()

        case "MODE_NUM":
            mode = .number
            isShifted = false
            isCapsLocked = false
            lastShiftTapTime = 0
            buildKeyboard()

        case "MODE_LETTER":
            mode = .letter
            isShifted = false
            isCapsLocked = false
            lastShiftTapTime = 0
            buildKeyboard()

        case "#+=":
            mode = .symbol
            buildKeyboard()

        case "123":
            mode = .number
            buildKeyboard()

        case "GLOBE":
            advanceToNextInputMode()

        case "SPACE":
            proxy.insertText(" ")
            let after = isPassword ? "" : (proxy.documentContextBeforeInput ?? "")
            recordEvent(before: before, current: after, isPassword: isPassword, key: key)
            suggestionBar.setSuggestions([])

        case "RETURN":
            proxy.insertText("\n")
            let after = isPassword ? "" : (proxy.documentContextBeforeInput ?? "")
            recordEvent(before: before, current: after, isPassword: isPassword, key: key)
            suggestionBar.setSuggestions([])

        default:
            let char = (mode == .letter && isShifted) ? key.uppercased() : key
            proxy.insertText(char)
            let after = isPassword ? "" : (proxy.documentContextBeforeInput ?? "")
            recordEvent(before: before, current: after, isPassword: isPassword, key: char)
            updateSuggestions()

            if mode == .letter && isShifted && !isCapsLocked {
                isShifted = false
                lastShiftTapTime = 0
                updateLetterButtonTitles()
                updateShiftButton()
            }
        }
    }

    @objc private func keyTouchDown(_ sender: UIButton) {
        animateKey(sender, pressed: true)
    }

    @objc private func keyTouchEnded(_ sender: UIButton) {
        animateKey(sender, pressed: false)
    }

    @objc private func deleteTouchDown(_ sender: UIButton) {
        stopRepeatingDelete()
        deleteBackwardAndRecord()
        deleteInitialTimer = Timer.scheduledTimer(withTimeInterval: deleteInitialRepeatDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.isDeleteLongPressActive = true
            self.recordCurrentKeyboardState(key: "⌫", eventType: "long_press_start")
            self.deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: self.deleteRepeatInterval, repeats: true) { [weak self] _ in
                self?.deleteBackwardAndRecord(eventType: "long_press_repeat")
            }
        }
    }

    @objc private func deleteTouchEnded(_ sender: UIButton) {
        if isDeleteLongPressActive {
            recordCurrentKeyboardState(key: "⌫", eventType: "long_press_end")
        }
        stopRepeatingDelete()
    }

    private func stopRepeatingDelete() {
        deleteInitialTimer?.invalidate()
        deleteInitialTimer = nil
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
        isDeleteLongPressActive = false
    }

    private func deleteBackwardAndRecord(eventType: String = "key") {
        let proxy = textDocumentProxy
        let isPassword = proxy.isSecureTextEntry ?? false
        let before = isPassword ? "" : (proxy.documentContextBeforeInput ?? "")
        proxy.deleteBackward()
        playKeyboardClick()
        let after = isPassword ? "" : (proxy.documentContextBeforeInput ?? "")
        recordEvent(before: before, current: after, isPassword: isPassword, key: "⌫", eventType: eventType)
        updateSuggestions()
    }

    private func recordCurrentKeyboardState(key: String, eventType: String) {
        let proxy = textDocumentProxy
        let isPassword = proxy.isSecureTextEntry ?? false
        let current = isPassword ? "" : (proxy.documentContextBeforeInput ?? "")
        recordEvent(before: current, current: current, isPassword: isPassword, key: key, eventType: eventType)
    }

    private func playKeyboardClick() {
        UIDevice.current.playInputClick()
    }

    private func animateKey(_ button: UIButton, pressed: Bool) {
        let duration = pressed ? keyPressAnimationDuration : keyReleaseAnimationDuration
        let transform = pressed
            ? CGAffineTransform(scaleX: keyPressedScale, y: keyPressedScale)
            : .identity

        // Shift button background on release is managed by updateShiftButton() in keyTapped,
        // so we skip the background animation here to avoid a conflicting transition.
        let isShiftButton = button === shiftButton
        let targetBackground: UIColor?
        if pressed {
            targetBackground = button.backgroundColor?.withAlphaComponent(0.78)
        } else if isShiftButton {
            targetBackground = nil
        } else {
            targetBackground = isActionKey(button.accessibilityIdentifier ?? "") ? actionKeyBackground : keyBackground
        }

        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            button.transform = transform
            if let bg = targetBackground {
                button.backgroundColor = bg
            }
            button.layer.shadowOpacity = pressed ? 0.12 : 0.3
        }
    }

    // MARK: - Suggestions

    private func updateSuggestions() {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        // Extract the last partial word (split on whitespace and punctuation)
        let partial = context
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .last ?? ""

        guard partial.count >= 1 else {
            suggestionBar.setSuggestions([])
            return
        }

        // Run the NLP completion lookup on a dedicated serial queue so it doesn't block
        // key-tap responsiveness on the main thread.
        suggestionQueue.async { [weak self] in
            guard let self else { return }
            let range = NSRange(location: 0, length: partial.utf16.count)
            let completions = self.backgroundTextChecker.completions(
                forPartialWordRange: range,
                in: partial,
                language: "en_US"
            ) ?? []

            let filtered = Array(completions
                .filter { $0.lowercased() != partial.lowercased() }
                .prefix(3))

            DispatchQueue.main.async { [weak self] in
                self?.suggestionBar.setSuggestions(filtered)
            }
        }
    }

    private func applySuggestion(_ word: String) {
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let partial = context
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .last ?? ""

        // Delete the partial word
        for _ in 0..<partial.utf16.count {
            textDocumentProxy.deleteBackward()
        }
        // Insert completed word followed by a space
        textDocumentProxy.insertText(word + " ")

        let isPassword = textDocumentProxy.isSecureTextEntry ?? false
        let before = isPassword ? "" : (context)
        let after  = isPassword ? "" : (textDocumentProxy.documentContextBeforeInput ?? "")
        recordEvent(before: before, current: after, isPassword: isPassword, key: word, eventType: "suggestion")

        suggestionBar.setSuggestions([])
    }

    /// Updates letter button labels in-place when shift toggles, avoiding a full rebuild.
    private func updateLetterButtonTitles() {
        for button in letterButtons {
            guard let key = button.accessibilityIdentifier else { continue }
            button.setTitle(isShifted ? key.uppercased() : key, for: .normal)
        }
    }

    /// Updates the shift key appearance to reflect normal / shifted / caps-locked state.
    private func updateShiftButton() {
        guard let btn = shiftButton else { return }
        if isCapsLocked {
            btn.backgroundColor = UIColor(white: 0.2, alpha: 1)
            btn.setTitleColor(.white, for: .normal)
        } else if isShifted {
            btn.backgroundColor = keyBackground
            btn.setTitleColor(.black, for: .normal)
        } else {
            btn.backgroundColor = actionKeyBackground
            btn.setTitleColor(.black, for: .normal)
        }
    }

    // MARK: - Event recording

    private func recordEvent(
        before: String,
        current: String,
        isPassword: Bool,
        key: String = "",
        eventType: String = "key"
    ) {
        guard let defaults = cachedDefaults else { return }

        // Build the event on the main thread using current state, then persist on background queue.
        let rawDataMode = KeyboardRawDataMode.fromSharedDefaults(defaults)
        let event: [String: Any] = [
            "timestamp":   Int64(Date().timeIntervalSince1970 * 1000),
            "packageName": "",
            "beforeText":  rawDataMode.maskedText(before),
            "currentText": rawDataMode.maskedText(current),
            "isPassword":  isPassword ? 1 : 0,
            "key":         rawDataMode.maskedKey(key, eventType: eventType),
            "eventType":   eventType,
        ]

        recordingQueue.async {
            var pending = defaults.array(forKey: KeyboardSharedKeys.pendingEvents) as? [[String: Any]] ?? []
            pending.append(event)
            defaults.set(pending, forKey: KeyboardSharedKeys.pendingEvents)
            // synchronize() is not called per-event; the system flushes UserDefaults
            // automatically, and KeyboardSensor polls on a 30-second timer.
        }
    }
}

// MARK: - SuggestionBarView

/// Horizontal bar showing up to 3 word completion candidates.
final class SuggestionBarView: UIView {

    var onSelect: ((String) -> Void)?

    private let stackView = UIStackView()
    private var suggestionButtons: [UIButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1)

        let separator = UIView()
        separator.backgroundColor = UIColor(white: 0.6, alpha: 0.4)
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        for i in 0..<3 {
            let btn = UIButton(type: .system)
            btn.titleLabel?.font = .systemFont(ofSize: 16)
            btn.setTitleColor(.black, for: .normal)
            btn.backgroundColor = .clear
            btn.tag = i
            btn.addTarget(self, action: #selector(suggestionTapped(_:)), for: .touchUpInside)
            btn.isHidden = true

            // Vertical divider between buttons
            if i > 0 {
                let divider = UIView()
                divider.backgroundColor = UIColor(white: 0.6, alpha: 0.4)
                divider.translatesAutoresizingMaskIntoConstraints = false
                btn.addSubview(divider)
                NSLayoutConstraint.activate([
                    divider.leadingAnchor.constraint(equalTo: btn.leadingAnchor),
                    divider.topAnchor.constraint(equalTo: btn.topAnchor, constant: 8),
                    divider.bottomAnchor.constraint(equalTo: btn.bottomAnchor, constant: -8),
                    divider.widthAnchor.constraint(equalToConstant: 0.5),
                ])
            }

            stackView.addArrangedSubview(btn)
            suggestionButtons.append(btn)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSuggestions(_ words: [String]) {
        for (i, btn) in suggestionButtons.enumerated() {
            if i < words.count {
                btn.setTitle(words[i], for: .normal)
                btn.isHidden = false
            } else {
                btn.setTitle(nil, for: .normal)
                btn.isHidden = true
            }
        }
    }

    @objc private func suggestionTapped(_ sender: UIButton) {
        guard let word = sender.currentTitle else { return }
        onSelect?(word)
    }
}
