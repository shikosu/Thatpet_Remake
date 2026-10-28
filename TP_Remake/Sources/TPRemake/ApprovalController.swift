import AppKit

/// Demandes de permission de Claude Code : bulle avec Autoriser / Refuser / Laisser Claude demander.
final class ApprovalController: NSObject {
    struct Request {
        let tool: String
        let detail: String
        let replyPath: String
        let expires: Date
    }

    enum Decision: String { case allow, deny, ask }

    private let anchor: NSWindow
    private let figure: () -> NSRect
    private let dataDir: DataDir
    private let below: () -> NSRect?
    var onDecision: ((Decision) -> Void)?

    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let more = NSTextField(labelWithString: "")
    private var queue: [Request] = []
    private var expiry: Timer?

    var pendingCount: Int { queue.count }

    /// Abandonne toutes les demandes en attente (sans répondre aux hooks) : pour les tests.
    func dismissAll() { queue.removeAll(); expiry?.invalidate(); panel.orderOut(nil) }

    /// - Parameter below: cadre de la bulle de chat si elle est ouverte (pour se placer au-dessus).
    init(anchor: NSWindow, figure: @escaping () -> NSRect, dataDir: DataDir, below: @escaping () -> NSRect?) {
        self.anchor = anchor
        self.figure = figure
        self.dataDir = dataDir
        self.below = below
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        title.font = .boldSystemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detail.maximumNumberOfLines = 7
        detail.lineBreakMode = .byTruncatingTail
        detail.preferredMaxLayoutWidth = 312
        detail.isSelectable = true
        more.font = .systemFont(ofSize: 11)
        more.textColor = .secondaryLabelColor

        func button(_ title: String, _ action: Selector, primary: Bool = false) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            if primary { b.bezelColor = .controlAccentColor }
            return b
        }
        let allow = button("Autoriser", #selector(allowTapped), primary: true)
        let deny = button("Refuser", #selector(denyTapped))
        let ask = button("Voir dans Claude", #selector(askTapped))
        let buttons = NSStackView(views: [allow, deny, ask])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, detail, more, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 340),
        ])
        panel.contentView = background
        self.stack = stack

        NotificationCenter.default.addObserver(self, selector: #selector(anchorMoved),
                                               name: NSWindow.didMoveNotification, object: anchor)
    }

    private var stack: NSStackView!

    func enqueue(_ request: Request) {
        queue.append(request)
        if queue.count == 1 { present() }
        else { refreshCounter() }
    }

    private func present() {
        guard let request = queue.first else {
            panel.orderOut(nil)
            expiry?.invalidate()
            return
        }
        title.stringValue = "Claude demande la permission : \(request.tool)"
        detail.stringValue = request.detail.isEmpty ? "(aucun détail)" : request.detail
        refreshCounter()
        relayout()
        panel.orderFrontRegardless()

        expiry?.invalidate()
        let remaining = max(0.1, request.expires.timeIntervalSinceNow)
        expiry = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            // Le hook a abandonné : Claude demande lui-même, on retire la bulle.
            self?.dataDir.appendLog("approval: délai dépassé (\(request.tool))")
            self?.finishCurrent(nil)
        }
    }

    private func refreshCounter() {
        let waiting = queue.count - 1
        more.stringValue = waiting > 0 ? "+ \(waiting) autre\(waiting > 1 ? "s" : "") en attente" : ""
        more.isHidden = waiting <= 0
        if panel.isVisible { relayout() }
    }

    /// Envoie la décision au hook (si `decision` est nul : délai dépassé, rien à envoyer) et passe à la suivante.
    private func finishCurrent(_ decision: Decision?) {
        guard let request = queue.first else { return }
        queue.removeFirst()
        if let decision {
            var body: [String: Any] = ["behavior": decision.rawValue]
            if decision == .deny { body["message"] = "Refusé par l'utilisateur depuis le personnage." }
            if let data = try? JSONSerialization.data(withJSONObject: body) {
                let sent = PetSocket.send(data, to: URL(fileURLWithPath: request.replyPath))
                dataDir.appendLog("approval: \(request.tool) -> \(decision.rawValue)\(sent ? "" : " (hook injoignable)")")
            }
            onDecision?(decision)
        }
        present()
    }

    /// Réponse automatique pour les tests : TPREMAKE_AUTOANSWER=allow|deny|ask.
    func autoAnswerIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["TPREMAKE_AUTOANSWER"], let d = Decision(rawValue: raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.finishCurrent(d) }
    }

    @objc private func allowTapped() { finishCurrent(.allow) }
    @objc private func denyTapped() { finishCurrent(.deny) }
    @objc private func askTapped() { finishCurrent(.ask) }
    @objc private func anchorMoved() { if panel.isVisible { reposition() } }

    private func relayout() {
        stack.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 340, height: stack.fittingSize.height))
        reposition()
    }

    /// À suivre quand le personnage bouge.
    /// La bulle ne suit que les déplacements du personnage, pas ses mouvements d'animation (elle resterait difficile à cliquer).
    func followPet() { if panel.isVisible, anchor.frame.origin != lastAnchorOrigin { reposition() } }
    private var lastAnchorOrigin = NSPoint.zero

    private func reposition() {
        lastAnchorOrigin = anchor.frame.origin
        let pet = figure()
        let size = panel.frame.size
        var origin = NSPoint(x: pet.midX - size.width / 2, y: pet.maxY + 4)
        if let chat = below() { origin.y = max(origin.y, chat.maxY + 8) }
        if let screen = anchor.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if origin.y + size.height > screen.maxY - 8 { origin.y = pet.minY - 4 - size.height }
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}
