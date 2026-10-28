import AppKit

/// Dimensions de la fenêtre : un cadre carré de `side` points (le personnage), plus 30 % de hauteur au-dessus
/// pour les particules et les effets (comme l'original).
enum PetGeometry {
    static func windowSize(forCanvas side: CGFloat) -> NSSize {
        NSSize(width: side, height: (side * 1.3).rounded(.down))
    }
}

/// Affiche la pose courante ; ne réagit à la souris que sur les pixels opaques.
final class PetView: NSView {
    private let container = CALayer()      // porte la déformation (effets) et l'opacité
    private let spriteB = CALayer()        // ancienne pose, visible pendant un fondu enchaîné
    private let spriteA = CALayer()        // pose courante
    private var particleRenderer: ParticleRenderer!
    private var image: CGImage?
    private var fadeSource: CGImage?
    private var mirrored = false
    private var anchor = CGPoint(x: 0.5, y: 0.035)

    /// Côté du cadre carré du personnage (en bas à gauche de la vue) ; la vue est plus haute pour les particules.
    var canvasSide: CGFloat = 256 { didSet { layoutLayers() } }

    var onClick: (() -> Void)?
    var onDragStart: ((NSPoint) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?
    var menuProvider: (() -> NSMenu)?
    /// Fichiers ou image déposés sur le personnage.
    var onDrop: ((NSPasteboard) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ChatModel.hasAttachable(sender.draggingPasteboard) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop?(sender.draggingPasteboard) ?? false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        canvasSide = frame.width
        registerForDraggedTypes([.fileURL, .png, .tiff])
        wantsLayer = true
        layer?.backgroundColor = .clear
        for sprite in [spriteB, spriteA] {
            sprite.magnificationFilter = .linear
            sprite.minificationFilter = .trilinear
            container.addSublayer(sprite)
        }
        spriteB.opacity = 0
        layer?.addSublayer(container)
        particleRenderer = ParticleRenderer(parent: layer!)
        layoutLayers()
        apply(PetTransform())
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let square = CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide)
        container.bounds = square
        spriteA.frame = square
        spriteB.frame = square
        particleRenderer?.resize(bounds)
        CATransaction.commit()
    }

    func show(_ frame: PetFrame) {
        image = frame.image
        mirrored = frame.flipped
        anchor = frame.anchor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteA.contents = frame.image
        CATransaction.commit()
    }

    /// Fondu enchaîné : l'ancienne pose reste dessous, la nouvelle apparaît par-dessus.
    func setCrossfade(_ fade: (from: CGImage, progress: CGFloat)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let fade {
            if fadeSource !== fade.from { spriteB.contents = fade.from; fadeSource = fade.from }
            spriteB.opacity = 1
            spriteA.opacity = Float(fade.progress)
        } else if fadeSource != nil || spriteA.opacity != 1 {
            fadeSource = nil
            spriteB.contents = nil
            spriteB.opacity = 0
            spriteA.opacity = 1
        }
        CATransaction.commit()
    }

    /// Applique les effets d'animation autour du point d'ancrage (pieds, tête ou centre).
    func apply(_ t: PetTransform) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.anchorPoint = anchor
        container.position = CGPoint(x: anchor.x * canvasSide, y: anchor.y * canvasSide)
        var transform = CATransform3DMakeTranslation(t.dx, t.dy, 0)
        transform = CATransform3DRotate(transform, t.rotation, 0, 0, 1)
        transform = CATransform3DScale(transform, t.sx * (mirrored ? -1 : 1), t.sy, 1)
        container.transform = transform
        container.opacity = Float(t.alpha)
        CATransaction.commit()
    }

    func renderParticles(_ sprites: [ParticleSprite]) { particleRenderer.render(sprites) }
    var renderedParticleCount: Int { particleRenderer.visibleCount }

    /// Vrai si le pixel (coordonnées de la vue) n'est pas transparent.
    func isOpaque(at point: NSPoint) -> Bool {
        guard let image, point.x >= 0, point.y >= 0, point.x < canvasSide, point.y < canvasSide else { return false }
        let px = mirrored ? canvasSide - point.x : point.x
        let x = Int(px / canvasSide * CGFloat(image.width))
        let y = Int((1 - point.y / canvasSide) * CGFloat(image.height))
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let provider = crop.dataProvider, let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else { return false }
        let bpp = crop.bitsPerPixel / 8
        switch crop.alphaInfo {
        case .premultipliedLast, .last: return bytes[bpp - 1] > 20
        case .premultipliedFirst, .first: return bytes[0] > 20
        default: return true
        }
    }

    // MARK: Souris : un clic ouvre la bulle, un glissement saisit le personnage.

    private var pressStart: NSPoint?
    private var dragging = false

    /// Bouton enfoncé sur le personnage (clic ou glissement en cours).
    var isPressed: Bool { pressStart != nil }

    /// Sans cela, le premier clic sur une fenêtre inactive ne ferait que l'activer et serait perdu.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressStart = NSEvent.mouseLocation
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStart else { return }
        let p = NSEvent.mouseLocation
        if !dragging {
            guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
            dragging = true
            onDragStart?(p)
        }
        onDragMove?(p)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { onDragEnd?(NSEvent.mouseLocation) } else if pressStart != nil { onClick?() }
        pressStart = nil
        dragging = false
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
