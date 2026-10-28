import AppKit

private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    let pasteEditor = PasteFieldEditor()
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        pasteEditor.isFieldEditor = true
        return pasteEditor
    }
}

/// Bulle au-dessus du personnage : champ de saisie + réponse courte.
final class BubbleController: NSObject, NSTextFieldDelegate {
    /// Au-delà, la réponse part dans la fenêtre de chat.
    static let shortLimit = 260

    private let model: ChatModel
    private let anchor: NSWindow
    private let figure: () -> NSRect
    private let openChat: () -> Void
    private let panel: BubblePanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private let field = NSTextField()
    private let stopButton = NSButton(title: "Arrêter", target: nil, action: nil)
    private let stack = NSStackView()
    private var hideTimer: Timer?
    private let attachments: AttachmentControls
    private var choosingFile = false

    init(model: ChatModel, anchor: NSWindow, figure: @escaping () -> NSRect, openChat: @escaping () -> Void) {
        self.model = model
        self.anchor = anchor
        self.figure = figure
        self.openChat = openChat
        attachments = AttachmentControls(model: model)
        panel = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = DropEffectView()
        background.acceptDrops()
        background.onDrop = { [weak model] in model?.attach(from: $0) ?? false }
        panel.pasteEditor.onPasteAttachment = { [weak model] in model?.attach(from: $0) ?? false }
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 292
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        field.placeholderString = "Écrire à Claude…"
        field.font = .systemFont(ofSize: 13)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.focusRingType = .none

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.isHidden = true

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(stopButton)
        let row = NSStackView(views: [attachments.plusButton, field])
        row.spacing = 6
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(attachments.chips)
        stack.addArrangedSubview(row)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 320),
            row.widthAnchor.constraint(equalToConstant: 292),
            attachments.chips.widthAnchor.constraint(equalToConstant: 292),
        ])
        panel.contentView = background
        attachments.onChoosing = { [weak self] choosing in
            guard let self else { return }
            choosingFile = choosing
            if !choosing { takeKeyboard() }
        }
        attachments.onChange = { [weak self] in if self?.panel.isVisible == true { self?.relayout() } }

        NotificationCenter.default.addObserver(self, selector: #selector(anchorMoved),
                                               name: NSWindow.didMoveNotification, object: anchor)
        NotificationCenter.default.addObserver(self, selector: #selector(panelResigned),
                                               name: NSWindow.didResignKeyNotification, object: panel)
    }

    var isVisible: Bool { panel.isVisible }
    var debugIsKey: Bool { panel.isKeyWindow && panel.firstResponder === field.currentEditor() }
    var frame: NSRect? { panel.isVisible ? panel.frame : nil }

    /// Clic sur le personnage : ouvre la bulle ; si elle est déjà là mais sans le clavier (réponse affichée),
    /// on lui rend le focus sans effacer la réponse ; si elle a le clavier, on la ferme.
    func toggleInput() {
        if !panel.isVisible { showInput() }
        else if panel.isKeyWindow { hide(restoreFocus: true) }
        else { focusInput() }
    }

    /// Application qui avait le clavier avant l'ouverture de la bulle (pour la lui rendre ensuite).
    private var previousApp: NSRunningApplication?

    private func takeKeyboard() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        hideTimer?.invalidate()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Redonne le clavier au champ de saisie en gardant la réponse affichée.
    func focusInput() {
        field.isEnabled = !model.isBusy
        takeKeyboard()
    }

    func showInput() {
        hideTimer?.invalidate()
        label.stringValue = ""
        label.isHidden = true
        stopButton.isHidden = true
        field.placeholderString = "Écrire à \(model.agent.speaker)…"
        field.isEnabled = true
        field.stringValue = ""
        relayout()
        takeKeyboard()
    }

    /// Ferme la bulle. `restoreFocus` : rend le clavier à l'application précédente (Échap, second clic),
    /// mais pas quand l'utilisateur est lui-même passé ailleurs.
    func hide(restoreFocus: Bool = false) {
        hideTimer?.invalidate()
        panel.orderOut(nil)
        guard restoreFocus, NSApp.isActive else { return }
        // Une fenêtre de chat ouverte garde le clavier.
        if NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) { return }
        previousApp?.activate(options: [])
    }

    /// Réponse (en cours ou finale) à afficher dans la bulle.
    func showReply(_ text: String, isFinal: Bool, isError: Bool) {
        hideTimer?.invalidate()
        let long = text.count > Self.shortLimit
        var shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if long { shown = String(shown.prefix(Self.shortLimit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        if shown.isEmpty { shown = "…" }
        label.attributedStringValue = Markdown.render(shown, size: 13, color: isError ? .systemRed : .labelColor)
        label.isHidden = false
        stopButton.isHidden = isFinal || !model.isBusy
        field.isEnabled = !model.isBusy || isFinal
        relayout()
        if !panel.isVisible { panel.orderFrontRegardless() }
        guard isFinal else { return }
        if long { openChat() }
        // Réponse courte et fenêtre non active : la bulle se retire seule.
        if !long && !panel.isKeyWindow {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.hide() }
        }
        if panel.isVisible { panel.makeFirstResponder(field) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let text = field.stringValue
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty || !model.attachments.isEmpty, !model.isBusy else { return true }
            field.stringValue = ""
            field.isEnabled = false
            label.stringValue = "…"
            label.textColor = .secondaryLabelColor
            label.isHidden = false
            stopButton.isHidden = false
            relayout()
            model.send(text)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            hide(restoreFocus: true)
            return true
        }
        return false
    }

    @objc private func stopTapped() { model.cancel() }

    @objc private func anchorMoved() { if panel.isVisible { reposition() } }

    @objc private func panelResigned() {
        // Clic ailleurs : on ferme, sauf si Claude est en train de répondre.
        DispatchQueue.main.async { [self] in
            if !panel.isKeyWindow, !choosingFile, !model.isBusy, field.stringValue.isEmpty { hideTimer?.invalidate(); hide() }
        }
    }

    private func relayout() {
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        panel.setContentSize(NSSize(width: 320, height: size.height))
        reposition()
    }

    /// À suivre quand le personnage bouge.
    /// La bulle ne suit que les déplacements du personnage, pas ses mouvements d'animation (elle resterait difficile à cliquer).
    func followPet() { if panel.isVisible, anchor.frame.origin != lastAnchorOrigin { reposition() } }
    private var lastAnchorOrigin = NSPoint.zero

    /// Centrée au-dessus de la tête du personnage (en dessous s'il n'y a pas de place), ramenée dans l'écran.
    private func reposition() {
        lastAnchorOrigin = anchor.frame.origin
        let pet = figure()
        let size = panel.frame.size
        var origin = NSPoint(x: pet.midX - size.width / 2, y: pet.maxY + 4)
        if let screen = anchor.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if origin.y + size.height > screen.maxY - 8 { origin.y = pet.minY - 4 - size.height }
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}
