import AppKit

/// Un élément de particule prêt à être dessiné (coordonnées de la fenêtre, origine en bas à gauche).
struct ParticleSprite {
    enum Shape { case z, dot, badge, star, rect, heart, drop, puff }
    var shape: Shape
    var position: CGPoint
    var size: CGFloat
    var rotation: CGFloat = 0
    var alpha: CGFloat = 1
    var scaleX: CGFloat = 1      // « flutter » des confettis (la pièce se retourne)
    var color: NSColor
}

/// Système de particules : effets continus (« périodiques ») tant qu'une animation est jouée, et rafales
/// déclenchées au début d'une animation. La logique est pure (testable) ; le dessin est dans `ParticleRenderer`.
final class ParticleSystem {
    /// Géométrie du moment, en coordonnées de la fenêtre.
    struct Frame {
        var figure: CGRect        // rectangle du personnage
        var floorY: CGFloat       // ordonnée du sol (pieds)
        var unit: CGFloat         // points par unité de conception
    }

    private struct Burst {
        var shape: ParticleSprite.Shape
        var born: Double          // peut être dans le futur (délai)
        var life: Double
        var origin: CGPoint
        var velocity: CGVector    // pt/s
        var gravity: CGFloat      // pt/s² (négatif = vers le bas)
        var size: CGFloat
        var endSize: CGFloat
        var spin: CGFloat         // rad/s
        var color: NSColor
        var flutter = false
        var twinkle = false       // taille en sin(π·âge) : apparaît, culmine, disparaît (étincelles)
        var sway: CGFloat = 0     // oscillation horizontale (cœurs)
        var accelDown = false     // chute accélérée (gouttes de sueur)
    }

    private var bursts: [Burst] = []
    private var rng: SplitMix64
    private var periodic: [String] = []
    private var periodicStart = 0.0
    var enabled = true

    /// Effets continus et rafales connus.
    static let periodicNames: Set<String> = ["zzz", "thought_dots", "exclaim"]
    static let burstNames: Set<String> = ["dust", "sweat", "confetti", "sparkle_small", "sparkle", "poof", "hearts"]

    init(seed: UInt64) { rng = SplitMix64(state: seed) }

    var aliveBursts: Int { bursts.count }

    /// Une animation démarre : on (re)lance ses effets continus et ses rafales.
    func animationStarted(particles: [String], now: Double, frame: Frame) {
        periodic = particles.filter { Self.periodicNames.contains($0) }
        periodicStart = now
        guard enabled else { return }
        for name in particles where Self.burstNames.contains(name) { spawn(name, now: now, frame: frame) }
    }

    func clear() { bursts.removeAll(); periodic.removeAll() }

    // MARK: - Rafales

    private func r(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: min(a, b)...max(a, b), using: &rng) }

    private func palette(_ hexes: [UInt32]) -> NSColor {
        let h = hexes[Int.random(in: 0..<hexes.count, using: &rng)]
        return NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1)
    }

    private func spawn(_ name: String, now: Double, frame f: Frame) {
        let u = f.unit
        let fig = f.figure
        let head = CGPoint(x: fig.midX, y: fig.maxY)
        switch name {
        case "confetti":
            for _ in 0..<32 {
                bursts.append(Burst(shape: .rect, born: now, life: r(1.5, 2.1), origin: CGPoint(x: head.x + r(-12, 12) * u, y: head.y - 10 * u),
                                    velocity: CGVector(dx: r(-150, 150) * u, dy: r(180, 330) * u), gravity: -520 * u,
                                    size: r(3, 5) * u, endSize: r(3, 5) * u, spin: r(-9, 9),
                                    color: palette([0xFF5A5F, 0xFFC947, 0x4DA8FF, 0x5ED38A, 0xFF8AD8, 0xB48CFF]), flutter: true))
            }
        case "sparkle_small", "sparkle":
            let n = name == "sparkle" ? 10 : 6
            for _ in 0..<n {
                bursts.append(Burst(shape: .star, born: now + Double(r(0, 0.35)), life: r(0.6, 0.95),
                                    origin: CGPoint(x: fig.midX + r(-0.6, 0.6) * fig.width, y: fig.midY + r(-0.55, 0.65) * fig.height),
                                    velocity: CGVector(dx: r(-12, 12) * u, dy: r(8, 28) * u), gravity: 0,
                                    size: r(4, 8) * u, endSize: r(4, 8) * u, spin: r(-3, 3), color: palette([0xFFE066, 0xFFF2A8, 0xFFFFFF]), twinkle: true))
            }
        case "hearts":
            for k in 0..<6 {
                bursts.append(Burst(shape: .heart, born: now + 0.45 + Double(k) * 0.08, life: r(1.2, 1.7),
                                    origin: CGPoint(x: head.x + r(-14, 14) * u, y: head.y - 14 * u),
                                    velocity: CGVector(dx: 0, dy: r(45, 85) * u), gravity: 0,
                                    size: r(4, 6) * u, endSize: r(8, 11) * u, spin: 0, color: palette([0xFF6FA3, 0xFF8FB8, 0xFF4F8B]), sway: r(8, 16) * u))
            }
        case "sweat":
            for side in [CGFloat(-1), 1] {
                for _ in 0..<2 {
                    bursts.append(Burst(shape: .drop, born: now + Double(r(0, 0.25)), life: r(0.7, 0.95),
                                        origin: CGPoint(x: head.x + side * r(9, 15) * u, y: head.y - r(10, 20) * u),
                                        velocity: CGVector(dx: side * r(10, 28) * u, dy: r(18, 45) * u), gravity: -260 * u,
                                        size: r(3, 4.5) * u, endSize: r(3, 4.5) * u, spin: 0, color: NSColor(srgbRed: 0.49, green: 0.78, blue: 1, alpha: 1), accelDown: true))
                }
            }
        case "poof":
            for k in 0..<10 {
                let a = CGFloat(k) / 10 * 2 * .pi + r(-0.2, 0.2)
                bursts.append(Burst(shape: .puff, born: now, life: r(0.5, 0.7), origin: CGPoint(x: fig.midX, y: fig.midY),
                                    velocity: CGVector(dx: cos(a) * r(70, 130) * u, dy: sin(a) * r(70, 130) * u), gravity: 0,
                                    size: r(6, 9) * u, endSize: r(14, 20) * u, spin: 0, color: palette([0xFFFFFF, 0xE6EAF2, 0xD3D9E6])))
            }
        case "dust":
            for k in 0..<8 {
                let side: CGFloat = k % 2 == 0 ? 1 : -1
                bursts.append(Burst(shape: .puff, born: now, life: r(0.45, 0.7), origin: CGPoint(x: fig.midX + side * r(2, 10) * u, y: f.floorY + 2 * u),
                                    velocity: CGVector(dx: side * r(45, 120) * u, dy: r(8, 30) * u), gravity: 0,
                                    size: r(4, 7) * u, endSize: r(10, 16) * u, spin: 0, color: palette([0xD9C9A8, 0xCDBA96, 0xE5D8BE])))
            }
        default: break
        }
    }

    // MARK: - Dessin

    /// Particules vivantes à l'instant `now`. Les rafales expirées sont retirées.
    func sprites(now: Double, frame f: Frame) -> [ParticleSprite] {
        guard enabled else { return [] }
        bursts.removeAll { now - $0.born > $0.life }
        var out: [ParticleSprite] = []
        for b in bursts where now >= b.born {
            let age = CGFloat(now - b.born)
            let p = age / CGFloat(b.life)
            var x = b.origin.x + b.velocity.dx * age + b.sway * sin(age * 5)
            var y = b.origin.y + b.velocity.dy * age + 0.5 * b.gravity * age * age
            if b.accelDown { y = b.origin.y + b.velocity.dy * age * (1 - p) + b.gravity * age * age * 0.5 }
            if !x.isFinite { x = b.origin.x }
            if !y.isFinite { y = b.origin.y }
            var size = b.size + (b.endSize - b.size) * p
            // Apparition en 12 % de la vie, disparition sur les 45 % finaux (courbes relevées dans l'original).
            var alpha = min(p / 0.12, 1)
            if p > 0.55 { let q = (p - 0.55) / 0.45; alpha *= 1 - q * q }
            if b.twinkle { size *= sin(.pi * p) }
            let flutter: CGFloat = b.flutter ? abs(cos(age * 10 + CGFloat(b.spin))) * 0.7 + 0.3 : 1
            out.append(ParticleSprite(shape: b.shape, position: CGPoint(x: x, y: y), size: size, rotation: b.spin * age,
                                      alpha: max(alpha, 0), scaleX: flutter, color: b.color))
        }
        out.append(contentsOf: periodicSprites(now: now, frame: f))
        return out
    }

    private func envelope(_ p: CGFloat, fadeIn: CGFloat, fadeOut: CGFloat) -> CGFloat {
        min(max(min(p / fadeIn, (1 - p) / fadeOut), 0), 1)
    }

    private func periodicSprites(now: Double, frame f: Frame) -> [ParticleSprite] {
        let age = now - periodicStart
        guard age >= 0 else { return [] }
        let u = f.unit
        let head = CGPoint(x: f.figure.midX, y: f.figure.maxY)
        var out: [ParticleSprite] = []
        for name in periodic {
            switch name {
            case "zzz":
                // Trois « z » décalés de 0,6 s, un cycle de 1,8 s : ils montent en grossissant vers le haut à droite.
                for k in 0..<3 where age >= Double(k) * 0.6 {
                    let cycle = (age - Double(k) * 0.6) / 1.8
                    let p = CGFloat(cycle - floor(cycle))
                    out.append(ParticleSprite(shape: .z, position: CGPoint(x: head.x + (14 + 11 * p) * u, y: head.y + (4 + 9 * p) * u),
                                              size: (7 + 3.6 * p) * u, rotation: -0.25 + 0.4 * p,
                                              alpha: envelope(p, fadeIn: 0.15, fadeOut: 0.35) * 0.9,
                                              color: NSColor(srgbRed: 0.45, green: 0.55, blue: 0.75, alpha: 1)))
                }
            case "thought_dots":
                // Trois points de taille croissante qui apparaissent l'un après l'autre (cycle de 1,2 s).
                let cycle = age / 1.2
                let p = CGFloat(cycle - floor(cycle))
                for k in 0..<3 {
                    let start = CGFloat(k) * 0.18
                    guard p >= start else { continue }
                    let local = min((p - start) / 0.12, 1)
                    out.append(ParticleSprite(shape: .dot, position: CGPoint(x: head.x + (8 + 6 * CGFloat(k)) * u, y: head.y + (5 + 7 * CGFloat(k)) * u),
                                              size: (2.4 + 1.5 * CGFloat(k)) * u * (0.5 + 0.5 * local),
                                              alpha: min(local, p > 0.85 ? (1 - p) / 0.15 : 1) * 0.95,
                                              color: NSColor(srgbRed: 0.85, green: 0.88, blue: 0.95, alpha: 1)))
                }
            case "exclaim":
                // Un « ! » qui jaillit au-dessus de la tête, toutes les 0,7 s.
                let cycle = age / 0.7
                let p = CGFloat(cycle - floor(cycle))
                let pop: CGFloat = p < 0.25 ? 0.55 + 0.6 * sin(p / 0.25 * .pi / 2) : 1.15 - 0.15 * min((p - 0.25) / 0.2, 1)
                out.append(ParticleSprite(shape: .badge, position: CGPoint(x: head.x + 20 * u, y: head.y + 12 * u),
                                          size: 18 * u * pop, alpha: p > 0.85 ? (1 - p) / 0.15 : 1,
                                          color: NSColor(srgbRed: 0.9, green: 0.28, blue: 0.3, alpha: 1)))
            default: break
            }
        }
        return out
    }
}

// MARK: - Rendu Core Animation

/// Dessine les `ParticleSprite` dans une couche transparente (pool de couches réutilisées).
final class ParticleRenderer {
    private let root = CALayer()
    private var pool: [CALayer] = []
    private var shapes: [ParticleSprite.Shape: CGPath] = [:]

    init(parent: CALayer) {
        root.zPosition = 10
        parent.addSublayer(root)
    }

    func resize(_ bounds: CGRect) { root.frame = bounds }

    /// Chemins unitaires centrés en (0,0), de côté 1.
    private func path(for shape: ParticleSprite.Shape) -> CGPath {
        if let cached = shapes[shape] { return cached }
        let p = CGMutablePath()
        switch shape {
        case .dot, .badge, .puff: p.addEllipse(in: CGRect(x: -0.5, y: -0.5, width: 1, height: 1))
        case .rect: p.addRect(CGRect(x: -0.5, y: -0.3, width: 1, height: 0.6))
        case .star:   // étoile à quatre branches
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                let rad: CGFloat = i % 2 == 0 ? 0.5 : 0.14
                let pt = CGPoint(x: cos(a) * rad, y: sin(a) * rad)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        case .heart:
            p.move(to: CGPoint(x: 0, y: -0.45))
            p.addCurve(to: CGPoint(x: -0.5, y: 0.1), control1: CGPoint(x: -0.2, y: -0.28), control2: CGPoint(x: -0.5, y: -0.1))
            p.addCurve(to: CGPoint(x: 0, y: 0.18), control1: CGPoint(x: -0.5, y: 0.4), control2: CGPoint(x: -0.1, y: 0.45))
            p.addCurve(to: CGPoint(x: 0.5, y: 0.1), control1: CGPoint(x: 0.1, y: 0.45), control2: CGPoint(x: 0.5, y: 0.4))
            p.addCurve(to: CGPoint(x: 0, y: -0.45), control1: CGPoint(x: 0.5, y: -0.1), control2: CGPoint(x: 0.2, y: -0.28))
            p.closeSubpath()
        case .drop:
            p.move(to: CGPoint(x: 0, y: 0.5))
            p.addCurve(to: CGPoint(x: 0, y: -0.5), control1: CGPoint(x: 0.5, y: -0.05), control2: CGPoint(x: 0.42, y: -0.5))
            p.addCurve(to: CGPoint(x: 0, y: 0.5), control1: CGPoint(x: -0.42, y: -0.5), control2: CGPoint(x: -0.5, y: -0.05))
            p.closeSubpath()
        case .z: break
        }
        shapes[shape] = p
        return p
    }

    /// Nombre de couches actuellement visibles (pour les diagnostics).
    var visibleCount: Int { pool.filter { !$0.isHidden }.count }

    func render(_ sprites: [ParticleSprite]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while pool.count < sprites.count {
            let layer = CAShapeLayer()
            layer.bounds = CGRect(x: -0.5, y: -0.5, width: 1, height: 1)
            layer.fillRule = .evenOdd   // le « ! » du badge est un trou
            root.addSublayer(layer)
            pool.append(layer)
        }
        for (i, layer) in pool.enumerated() {
            guard i < sprites.count else { layer.isHidden = true; continue }
            let s = sprites[i]
            layer.isHidden = false
            layer.position = s.position
            layer.opacity = Float(s.alpha)
            layer.transform = CATransform3DScale(CATransform3DMakeRotation(s.rotation, 0, 0, 1), s.size * s.scaleX, s.size, 1)
            guard let shape = layer as? CAShapeLayer else { continue }
            shape.fillColor = s.color.cgColor
            shape.path = s.shape == .z ? glyphPath("z") : s.shape == .badge ? badgePath() : path(for: s.shape)
        }
        CATransaction.commit()
    }

    private var glyphCache: [String: CGPath] = [:]

    /// Lettre « z » tracée comme un chemin (taille 1, centrée), pour rester un simple CAShapeLayer.
    private func glyphPath(_ text: String) -> CGPath {
        if let cached = glyphCache[text] { return cached }
        let p = CGMutablePath()
        // « z » stylisé : trait haut, diagonale, trait bas (épaissi en polygone).
        p.addLines(between: [CGPoint(x: -0.4, y: 0.42), CGPoint(x: 0.42, y: 0.42), CGPoint(x: 0.42, y: 0.26), CGPoint(x: -0.12, y: -0.26),
                             CGPoint(x: 0.42, y: -0.26), CGPoint(x: 0.42, y: -0.42), CGPoint(x: -0.42, y: -0.42), CGPoint(x: -0.42, y: -0.26),
                             CGPoint(x: 0.12, y: 0.26), CGPoint(x: -0.4, y: 0.26)])
        p.closeSubpath()
        glyphCache[text] = p
        return p
    }

    /// Pastille ronde avec un point d'exclamation évidé (even-odd).
    private func badgePath() -> CGPath {
        if let cached = glyphCache["badge"] { return cached }
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: -0.5, y: -0.5, width: 1, height: 1))
        p.addRoundedRect(in: CGRect(x: -0.06, y: -0.02, width: 0.12, height: 0.32), cornerWidth: 0.05, cornerHeight: 0.05)
        p.addEllipse(in: CGRect(x: -0.07, y: -0.3, width: 0.14, height: 0.14))
        glyphCache["badge"] = p
        return p
    }
}
