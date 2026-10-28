import AppKit

/// Petite bulle qui dit ce que fait l'agent (« Lance une commande », « Réfléchit… »). Ne capte jamais la souris.
final class ActivityBubble {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let anchor: NSWindow
    private let figure: () -> NSRect
    private var hideTimer: Timer?
    private(set) var text = ""
    /// Quand une autre bulle (chat, approbation) est affichée, celle-ci s'efface pour ne pas la recouvrir.
    var suppressed = false { didSet { refreshVisibility() } }
    var enabled = true { didSet { refreshVisibility() } }

    init(anchor: NSWindow, figure: @escaping () -> NSRect) {
        self.anchor = anchor
        self.figure = figure
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 26),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 0

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0 }

    /// Affiche (ou met à jour) le texte. `persistent` : reste tant que l'état dure (attention) ; sinon s'efface seule.
    func show(_ newText: String, persistent: Bool = false) {
        text = newText
        label.stringValue = newText
        let size = NSSize(width: ceil(label.intrinsicContentSize.width) + 28, height: 26)
        panel.setContentSize(size)
        panel.contentView?.layer?.cornerRadius = size.height / 2
        hideTimer?.invalidate()
        if !persistent { hideTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.hide() } }
        reposition()
        refreshVisibility()
    }

    func hide() {
        hideTimer?.invalidate()
        text = ""
        refreshVisibility()
    }

    func follow() { if panel.isVisible { reposition() } }

    private func refreshVisibility() {
        let shouldShow = enabled && !suppressed && !text.isEmpty
        if shouldShow {
            reposition()
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        } else if panel.isVisible {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in if self?.text.isEmpty ?? true || self?.suppressed ?? false { self?.panel.orderOut(nil) } })
        }
    }

    /// Au-dessus de la tête, en dessous s'il n'y a pas de place, toujours dans l'écran.
    private func reposition() {
        let pet = figure()
        let size = panel.frame.size
        var origin = NSPoint(x: pet.midX - size.width / 2, y: pet.maxY + 6)
        if let screen = anchor.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if origin.y + size.height > screen.maxY - 4 { origin.y = pet.minY - 6 - size.height }
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        }
        panel.setFrameOrigin(origin)
    }
}
