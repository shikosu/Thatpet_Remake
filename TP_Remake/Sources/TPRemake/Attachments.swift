import AppKit

/// Bouton « + » et liste des fichiers joints, partagés par la bulle et la fenêtre de chat.
final class AttachmentControls: NSObject {
    let plusButton = NSButton()
    /// « 📎 a.png, b.pdf  ✕ » : caché quand rien n'est joint.
    let chips = NSStackView()
    private let chipsLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private let model: ChatModel
    /// Appelé avant/après le sélecteur de fichiers (la bulle ne doit pas se fermer pendant ce temps).
    var onChoosing: ((Bool) -> Void)?
    /// Appelé quand la liste change (pour réajuster la mise en page).
    var onChange: (() -> Void)?

    init(model: ChatModel) {
        self.model = model
        super.init()
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Joindre des fichiers")
        plusButton.bezelStyle = .circular
        plusButton.controlSize = .small
        plusButton.toolTip = "Joindre des fichiers"
        plusButton.target = self
        plusButton.action = #selector(choose)
        plusButton.setContentHuggingPriority(.required, for: .horizontal)

        chipsLabel.font = .systemFont(ofSize: 11)
        chipsLabel.textColor = .secondaryLabelColor
        chipsLabel.lineBreakMode = .byTruncatingMiddle
        chipsLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Retirer les fichiers")
        clearButton.isBordered = false
        clearButton.toolTip = "Retirer les fichiers joints"
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)
        chips.orientation = .horizontal
        chips.spacing = 6
        chips.addArrangedSubview(chipsLabel)
        chips.addArrangedSubview(clearButton)

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .chatChanged, object: model)
        refresh()
    }

    @objc func refresh() {
        let files = model.attachments
        let text = files.isEmpty ? "" : "📎 " + files.map(\.lastPathComponent).joined(separator: ", ")
        plusButton.isEnabled = !model.isBusy
        // La mise en page ne bouge que si la liste a changé (refresh arrive aussi à chaque morceau de réponse).
        guard text != chipsLabel.stringValue else { return }
        chipsLabel.stringValue = text
        chips.isHidden = files.isEmpty
        onChange?()
    }

    @objc private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Joindre"
        panel.message = "Fichiers ou dossiers à montrer à l'agent."
        onChoosing?(true)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { model.attach(panel.urls) }
        onChoosing?(false)
    }

    @objc private func clear() { model.clearAttachments() }
}

// MARK: - Glisser-déposer et collage

extension ChatModel {
    /// Joint ce que contient le presse-papiers ou le glisser-déposer : fichiers, sinon image (enregistrée en PNG).
    /// Faux si rien d'exploitable (un simple texte se colle normalement).
    @discardableResult
    func attach(from pasteboard: NSPasteboard) -> Bool {
        guard !isBusy else { return false }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            attach(urls)
            return true
        }
        guard let png = Self.pngData(from: pasteboard) else { return false }
        let folder = attachmentsDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let file = folder.appendingPathComponent("image-\(stamp.string(from: Date())).png")
        guard (try? png.write(to: file)) != nil else { return false }
        attach([file])
        return true
    }

    /// Images collées ou glissées : gardées 7 jours puis supprimées au démarrage.
    func pruneAttachments() {
        let old = Date().addingTimeInterval(-7 * 86400)
        let files = (try? FileManager.default.contentsOfDirectory(at: attachmentsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < old { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) { return data }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Vrai si le presse-papiers porte des fichiers ou une image (et pas seulement du texte).
    static func hasAttachable(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return pasteboard.data(forType: .png) != nil || (pasteboard.data(forType: .tiff) != nil && pasteboard.string(forType: .string) == nil)
    }
}

/// Vue qui accepte des fichiers ou images déposés.
class DropView: NSView {
    var onDrop: ((NSPasteboard) -> Bool)?

    func acceptDrops() { registerForDraggedTypes([.fileURL, .png, .tiff]) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ChatModel.hasAttachable(sender.draggingPasteboard) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop?(sender.draggingPasteboard) ?? false }
}

final class DropEffectView: NSVisualEffectView {
    var onDrop: ((NSPasteboard) -> Bool)?
    func acceptDrops() { registerForDraggedTypes([.fileURL, .png, .tiff]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ChatModel.hasAttachable(sender.draggingPasteboard) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop?(sender.draggingPasteboard) ?? false }
}

/// Éditeur du champ de saisie : Cmd+V joint les fichiers ou l'image copiés, sinon colle le texte.
final class PasteFieldEditor: NSTextView {
    var onPasteAttachment: ((NSPasteboard) -> Bool)?
    override func paste(_ sender: Any?) {
        if ChatModel.hasAttachable(.general), onPasteAttachment?(.general) == true { return }
        super.paste(sender)
    }
}
