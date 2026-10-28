import AppKit

struct PetFrame {
    let image: CGImage
    let pose: String
    let flipped: Bool
    /// Point d'ancrage normalisé (origine en bas à gauche, comme CALayer).
    let anchor: CGPoint
}

/// Joue les animations d'un pack. Piloté par le temps (`update(now:)`) : pas de minuteur, donc testable hors écran.
final class AnimationPlayer {
    private var pack: Pack
    private(set) var current = "idle"
    private(set) var currentPose = "idle_stand"
    private var frameIndex = 0
    private var playsLeft = 0
    private var frameStart = 0.0
    private var animStart = 0.0
    private var lastNow = 0.0
    private var generation = 0
    private var pendulum = PendulumState()
    /// Numéro de l'animation en cours (change à chaque `play`) : sert à ne déclencher les particules qu'une fois.
    private(set) var serial = 0

    // Fondu enchaîné (`xfade`) : pendant les premières ms d'une image, l'ancienne pose reste dessous.
    private var fadeFrom: CGImage?
    private var fadeDuration = 0.0

    /// Image miroir (grimper sur le mur de droite). À fixer avant `play`.
    var flipped = false
    /// En pause, l'image et les effets restent figés (personnage survolé, bulle ouverte…).
    var paused = false
    /// Points par « unité » de conception (= taille appliquée) : échelle des amplitudes des effets.
    var unit: Double = 1.6
    /// Vitesse du personnage ou du pointeur (pt/s), fournie par le cerveau : pendule, étirements.
    var motion = CGVector.zero
    var jumpSpeed: Double = 900

    var onFrame: ((PetFrame) -> Void)?
    /// Une animation non bouclée vient de se terminer ; si on ne lance rien d'autre, `next` (ou idle) suit.
    var onEnd: ((String) -> Void)?
    /// Une animation démarre (nom, particules déclarées dans le pack).
    var onStart: ((String, [String]) -> Void)?

    init(pack: Pack) { self.pack = pack }

    /// Change de personnage : repart de l'animation « idle » du nouveau pack.
    func replacePack(_ new: Pack) {
        pack = new
        flipped = false
        fadeFrom = nil
        play("idle")
    }

    var currentAnimation: Pack.Animation? { pack.animations[current] }

    func play(_ name: String) {
        guard let anim = pack.animations[name] else { return }
        generation += 1
        serial += 1
        let previousPose = currentPose
        current = name
        frameIndex = 0
        playsLeft = anim.loop ? Int.max : max(1, anim.repeatCount)
        frameStart = lastNow
        animStart = lastNow
        pendulum = PendulumState(theta: pendulum.theta * 0.5, omega: 0, lastT: 0)
        show(anim, previousPose: previousPose)
        onStart?(name, anim.particles)
    }

    /// Lance l'animation seulement si ce n'est pas déjà celle en cours.
    func ensure(_ name: String) { if current != name { play(name) } }

    func update(now: Double) {
        if paused {
            let skipped = now - lastNow
            frameStart += skipped
            animStart += skipped
            lastNow = now
            return
        }
        lastNow = now
        guard let anim = pack.animations[current] else { return }
        var guardCount = 0
        while guardCount < 16, now - frameStart >= Double(anim.frames[frameIndex].ms) / 1000 {
            guardCount += 1
            frameStart += Double(anim.frames[frameIndex].ms) / 1000
            frameIndex += 1
            let previousPose = currentPose
            if frameIndex >= anim.frames.count {
                frameIndex = 0
                if playsLeft != Int.max { playsLeft -= 1 }
                if playsLeft <= 0 {
                    let started = generation
                    let finished = current
                    onEnd?(finished)
                    if generation == started { play(anim.next ?? "idle") }
                    return
                }
            }
            show(anim, previousPose: previousPose)
        }
    }

    private func show(_ anim: Pack.Animation, previousPose: String) {
        let pose = anim.frames[frameIndex].pose
        currentPose = pose
        guard let image = pack.poses[pose] else { return }
        // Fondu depuis la pose précédente si l'animation en demande un et que la pose change.
        if anim.xfade > 0, previousPose != pose, let old = pack.poses[previousPose] {
            fadeFrom = old
            fadeDuration = Double(anim.xfade) / 1000
        } else {
            fadeFrom = nil
            fadeDuration = 0
        }
        onFrame?(PetFrame(image: image, pose: pose, flipped: flipped && anim.mirrorOnRightWall, anchor: anchor(for: pose)))
    }

    private func anchor(for pose: String) -> CGPoint {
        switch pack.anchors[pose] {
        case "top": return CGPoint(x: 0.5, y: 1)
        case "center", "wall": return CGPoint(x: 0.5, y: 0.5)
        default: return CGPoint(x: 0.5, y: 1 - pack.floor)   // feet
        }
    }

    /// Image actuellement miroir ?
    var isFlipped: Bool { flipped && (pack.animations[current]?.mirrorOnRightWall ?? false) }

    /// Ancienne pose encore visible pendant le fondu, et progression (0 → 1) de la nouvelle.
    func crossfade(now: Double) -> (from: CGImage, progress: CGFloat)? {
        guard let from = fadeFrom, fadeDuration > 0 else { return nil }
        let p = (now - frameStart) / fadeDuration
        guard p < 1 else { return nil }
        let c = min(max(p, 0), 1)
        return (from, CGFloat(c * c * (3 - 2 * c)))
    }

    /// Plage de temps (s) des images « spin » de l'animation courante, pour l'effet spin_hop.
    private func spinSpan(_ anim: Pack.Animation) -> (start: Double, end: Double)? {
        var t = 0.0
        var start: Double?, end: Double?
        for frame in anim.frames {
            let d = Double(frame.ms) / 1000
            if frame.pose.contains("spin") { start = start ?? t; end = t + d }
            t += d
        }
        guard let start, let end else { return nil }
        return (start, end)
    }

    /// Cumul des effets de l'animation courante à l'instant `now`.
    func transform(now: Double) -> PetTransform {
        guard let anim = pack.animations[current] else { return PetTransform() }
        let ms = Double(anim.frames[min(frameIndex, anim.frames.count - 1)].ms)
        var input = FxInput()
        input.t = max(0, now - animStart)
        input.frameT = max(0, now - frameStart)
        input.frameDur = ms / 1000
        input.unit = unit
        input.vx = motion.dx
        input.vy = motion.dy
        input.jumpSpeed = jumpSpeed
        input.spin = anim.fx.contains("spin_hop") ? spinSpan(anim) : nil
        return Fx.evaluate(anim.fx, input, pendulum: &pendulum)
    }
}
