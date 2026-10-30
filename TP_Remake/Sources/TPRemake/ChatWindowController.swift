import AppKit

private final class ChatWindow: NSWindow {
    let pasteEditor = PasteFieldEditor()
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        pasteEditor.isFieldEditor = true
        return pasteEditor
    }
}

/// Fenêtre de chat avec l'historique complet (pour les réponses longues).
final class ChatWindowController: NSObject, NSTextFieldDelegate {
    private let model: ChatModel
    private let window: ChatWindow
    private let textView = NSTextView()
    private let field = NSTextField()
    private let stopButton = NSButton(title: "Arrêter", target: nil, action: nil)
    private let attachments: AttachmentControls

    init(model: ChatModel) {
        self.model = model
        attachments = AttachmentControls(model: model)
        window = ChatWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Chat — Claude Code"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 300)
        window.center()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        field.placeholderString = "Écrire à Claude… (Entrée pour envoyer)"
        field.delegate = self
        field.bezelStyle = .roundedBezel

        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.isHidden = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [attachments.plusButton, field, stopButton])
        row.spacing = 8
        let bar = NSStackView(views: [attachments.chips, row])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true

        let content = DropView()
        content.acceptDrops()
        content.onDrop = { [weak model] in model?.attach(from: $0) ?? false }
        window.pasteEditor.onPasteAttachment = { [weak model] in model?.attach(from: $0) ?? false }
        for v in [scroll, bar] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window.contentView = content

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .chatChanged, object: model)
        reload()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    @objc private func reload() {
        window.title = "Chat — \(model.title)"
        field.placeholderString = "Écrire à \(model.agent.speaker)… (Entrée pour envoyer)"
        let out = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: 13)
        for (index, message) in model.messages.enumerated() {
            let isUser = message.role == .user
            out.append(NSAttributedString(string: (isUser ? "Vous" : model.agent.speaker) + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: isUser ? NSColor.secondaryLabelColor : NSColor.controlAccentColor,
            ]))
            let color: NSColor = message.isError ? .systemRed : .labelColor
            let working = index == model.messages.count - 1 ? model.currentStep.map { "⏳ " + $0 } : nil
            let body = message.text.isEmpty ? (working ?? "…") : message.text
            // Les messages de l'utilisateur restent bruts ; ceux de l'agent sont mis en forme.
            out.append(isUser
                ? NSAttributedString(string: body, attributes: [.font: base, .foregroundColor: color])
                : Markdown.render(body, size: 13, color: color))
            out.append(NSAttributedString(string: "\n\n"))
        }
        if model.messages.isEmpty {
            out.append(NSAttributedString(string: "Aucun message pour l'instant.", attributes: [
                .font: base, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        // On ne ramène en bas que si l'utilisateur y était déjà : il peut relire plus haut pendant que la réponse arrive.
        let scroll = textView.enclosingScrollView
        let visible = scroll?.contentView.bounds ?? .zero
        let wasAtBottom = scroll == nil || visible.maxY >= textView.frame.height - 40 || textView.frame.height <= visible.height
        textView.textStorage?.setAttributedString(out)
        if wasAtBottom { textView.scrollToEndOfDocument(nil) } else { scroll?.contentView.scroll(to: visible.origin) }
        field.isEnabled = !model.isBusy
        stopButton.isHidden = !model.isBusy
    }

    @objc private func stopTapped() { model.cancel() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let text = field.stringValue
        if !text.trimmingCharacters(in: .whitespaces).isEmpty || !model.attachments.isEmpty, !model.isBusy {
            field.stringValue = ""
            model.send(text)
        }
        return true
    }
}
