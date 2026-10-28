import AppKit

/// Générateur déterministe (graine fixe pour les simulations).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

/// Le comportement du personnage : marche au sol, grimpe aux murs, rampe au plafond, saute, tombe,
/// et réagit à la souris (saisie, lancer) et aux agents. Ne connaît pas l'écran : il manipule la position de
/// la fenêtre (`position`, origine en bas à gauche) dans un rectangle `world` (la zone visible d'un écran).
final class PetBrain {
    enum Side { case left, right }

    enum Mode {
        case standing(until: Double)
        case walking(targetX: CGFloat)
        case toWall(Side)
        case climbing(Side, stopWy: CGFloat, thenCeiling: Bool)
        case ceiling(dir: CGFloat, targetX: CGFloat)
        case launching(targetX: CGFloat)
        case air(vx: CGFloat, vy: CGFloat, jump: Bool)
        case landing
        case dragging
        case sleeping
        /// Animation imposée sur place (réaction à un agent, démo). `until` nil : jusqu'à nouvel ordre.
        case held(until: Double?)

        var name: String {
            switch self {
            case .standing: "standing"; case .walking: "walking"; case .toWall: "toWall"; case .climbing: "climbing"
            case .ceiling: "ceiling"; case .launching: "launching"; case .air: "air"; case .landing: "landing"
            case .dragging: "dragging"; case .sleeping: "sleeping"; case .held: "held"
            }
        }
    }

    struct Config {
        var gravity: CGFloat = 2400
        var restitution: CGFloat = 0.4
        var walkSpeed: CGFloat = 80
        var climbSpeed: CGFloat = 95
        var ceilingSpeed: CGFloat = 60
        var jumpSpeed: CGFloat = 900
        var maxThrow: CGFloat = 4000
        var sleepAfter: Double = 300
    }

    private(set) var pack: Pack
    let player: AnimationPlayer
    /// Côté (points) du cadre carré du personnage.
    private(set) var size: CGFloat
    var config = Config()
    private(set) var world: NSRect
    private(set) var position: CGPoint = .zero
    private(set) var mode: Mode = .standing(until: 0)
    private var rng: SplitMix64

    /// Se promène quand rien d'autre ne se passe (réglage utilisateur).
    var wander = true
    /// Vrai quand l'utilisateur interagit (bulle ouverte, approbation, réponse en cours) : le personnage reste là.
    var hold: () -> Bool = { false }
    /// Le pointeur est sur le personnage : il s'arrête pour pouvoir être cliqué, puis repart.
    var hover = false

    private var agentAnim: String?
    private var lastTick: Double
    private var lastActivity: Double
    // Saisie
    private var samples: [(t: Double, p: CGPoint)] = []
    private var dragSwing = 0
    private var lastPointer = CGPoint.zero

    init(pack: Pack, player: AnimationPlayer, size: CGFloat, world: NSRect, seed: UInt64, now: Double) {
        self.pack = pack
        self.player = player
        self.size = size
        self.world = world
        self.rng = SplitMix64(state: seed)
        self.lastTick = now
        self.lastActivity = now
        player.onEnd = { [unowned self] in self.animationEnded($0, now: self.lastTick) }
        player.update(now: now)
        // Départ : au sol, près du coin bas droit.
        player.flipped = false
        position = CGPoint(x: clampX(world.maxX - size - 40, bounds(of: "idle_stand")), y: floorWy)
        enterStanding(now: now)
    }

    /// Plus grand cadre dont toutes les poses (même la plus haute, accroché au plafond) tiennent dans la zone visible.
    var maxCanvas: CGFloat {
        PetBrain.maxCanvas(pack: pack, world: world)
    }

    static func maxCanvas(pack: Pack, world: NSRect) -> CGFloat {
        min(world.height * 0.95 / pack.tallestPose, world.width * 0.95 / pack.widestPose)
    }

    /// Union des contours de toutes les images de marche : bornes sûres pour marcher sans jamais « rater » une cible,
    /// puisque le contour change d'une image à l'autre.
    private var walkBounds: CGRect {
        let poses = ["walk_left", "walk_right"].flatMap { pack.animations[$0]?.frames.map { $0.pose } ?? [] }
        let rects = poses.compactMap { pack.bounds[$0] }
        guard var union = rects.first else { return bounds(of: "idle_stand") }
        for r in rects.dropFirst() { union = union.union(r) }
        return union
    }

    /// Union des contours des images d'escalade : le haut du personnage ne dépasse jamais, quelle que soit l'image.
    private var climbBounds: CGRect {
        let poses = pack.animations["climb"]?.frames.map { $0.pose } ?? []
        let rects = poses.compactMap { pack.bounds[$0] }
        guard var union = rects.first else { return bounds(of: "climb_1") }
        for r in rects.dropFirst() { union = union.union(r) }
        return union
    }

    /// Change la taille : le personnage reste au même endroit (même milieu), debout au sol.
    func resize(to newSize: CGFloat, now: Double) {
        guard newSize != size, newSize > 0 else { return }
        if case .dragging = mode { size = newSize; return }   // `place` recale le personnage au prochain tick
        let centerX = figure.midX
        size = newSize
        player.flipped = false
        position.x = centerX - currentBounds.midX * size
        if agentAnim != nil { enterHeld(now: now) } else { enterStanding(now: now) }
    }

    /// Change de personnage sur place : même position, nouvelle apparence, retour à la station debout.
    func replacePack(_ new: Pack, now: Double) {
        guard case .dragging = mode else {
            pack = new
            player.replacePack(new)
            position.y = floorWy
            if agentAnim != nil { enterHeld(now: now) } else { enterStanding(now: now) }
            return
        }
    }

    // MARK: - Géométrie

    /// Zone opaque d'une pose (fractions du cadre, origine en haut à gauche), miroir compris.
    private func bounds(of pose: String, flipped: Bool = false) -> CGRect {
        let r = pack.bounds[pose] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return flipped ? CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height) : r
    }

    private var currentBounds: CGRect { bounds(of: player.currentPose, flipped: player.isFlipped) }

    /// Rectangle (écran) occupé par le personnage.
    var figure: NSRect {
        let r = currentBounds
        return NSRect(x: position.x + r.minX * size, y: position.y + size * (1 - r.maxY), width: r.width * size, height: r.height * size)
    }

    private var floorWy: CGFloat { world.minY - (1 - pack.floor) * size }
    private func minWx(_ r: CGRect) -> CGFloat { world.minX - r.minX * size }
    private func maxWx(_ r: CGRect) -> CGFloat { world.maxX - r.maxX * size }
    private func ceilingWy(_ r: CGRect) -> CGFloat { world.maxY - size * (1 - r.minY) }
    private func clampX(_ x: CGFloat, _ r: CGRect) -> CGFloat { min(max(x, minWx(r)), max(minWx(r), maxWx(r))) }

    var isMoving: Bool {
        switch mode {
        case .walking, .toWall, .climbing, .ceiling, .air, .dragging: true
        default: false
        }
    }

    // MARK: - Boucle

    func tick(now: Double) {
        let dt = CGFloat(min(max(now - lastTick, 0), 0.05))
        lastTick = now
        // Le lecteur d'animation a besoin de l'échelle et de la vitesse pour ses effets (pendule, étirements…).
        player.unit = Double(size * pack.standHeight / 160)
        player.jumpSpeed = Double(config.jumpSpeed)
        switch mode {
        case .dragging: player.motion = velocity()
        case .air(let vx, let vy, _): player.motion = CGVector(dx: vx, dy: vy)
        default: player.motion = .zero
        }
        player.update(now: now)
        let interacting = hold()
        if interacting || hover { lastActivity = now }
        var freeze = false   // fige position et animation : le personnage « attend » sans changer d'état
        defer { player.paused = freeze }

        switch mode {
        case .dragging:
            updateDragPose(now: now)   // le pointeur peut s'être arrêté : plus d'évènement, mais la pose doit suivre
        case .landing:
            break
        case .standing(let until):
            if agentAnim != nil { enterHeld(now: now) }
            else if !interacting && !hover && now >= until { pickNext(now: now) }
            else if !interacting && !hover && now - lastActivity > config.sleepAfter { mode = .sleeping; player.flipped = false; player.play("sleep") }
        case .sleeping:
            if agentAnim != nil || interacting { enterStanding(now: now) }
        case .held(let until):
            if let until, now >= until { enterStanding(now: now) }
        case .walking(let target):
            if agentAnim != nil || interacting { enterStanding(now: now) }
            else if hover { freeze = true }
            else { walk(toward: target, dt: dt, now: now) { self.enterStanding(now: now) } }
        case .toWall(let side):
            if agentAnim != nil || interacting { enterStanding(now: now) }
            else if hover { freeze = true }
            else {
                let r = walkBounds
                let target = side == .left ? minWx(r) : maxWx(r)
                walk(toward: target, dt: dt, now: now) { self.startClimb(side, now: now) }
            }
        case .climbing(let side, let stopWy, let thenCeiling):
            if agentAnim != nil { startFall(now: now) }
            else if interacting || hover { freeze = true }   // sur le mur, on attend sans tomber
            else { climb(side, stopWy: stopWy, thenCeiling: thenCeiling, dt: dt, now: now) }
        case .ceiling(let dir, let target):
            if agentAnim != nil { startFall(now: now) }
            else if interacting || hover { freeze = true }
            else { crawl(dir: dir, target: target, dt: dt, now: now) }
        case .launching:
            if agentAnim != nil || interacting { enterStanding(now: now) }   // pas encore décollé
        case .air(let vx, let vy, let jump):
            fly(vx: vx, vy: vy, jump: jump, dt: dt, now: now)
        }
        position.x = position.x.isFinite ? position.x : 0
        position.y = position.y.isFinite ? position.y : floorWy
        // Le contour opaque change d'une image à l'autre (clignement, regard…) : au sol on se recadre à chaque image.
        switch mode {
        case .standing, .sleeping, .held, .launching, .landing: position.x = clampX(position.x, currentBounds)
        case .air:
            // La pose change au début de la chute (silhouette plus basse que debout) : on reste dans la zone.
            let r = currentBounds
            position.y = max(position.y, world.minY - size * (1 - r.maxY))
            position.y = min(position.y, ceilingWy(r))
        default: break
        }
    }

    // MARK: - États

    private func enterStanding(now: Double) {
        player.flipped = false
        mode = .standing(until: now + Double.random(in: 2...6, using: &rng))
        player.play(Double.random(in: 0..<1, using: &rng) < 0.7 ? "idle" : "sit")
        position.y = floorWy
        position.x = clampX(position.x, bounds(of: player.currentPose))
    }

    private func enterHeld(now: Double) {
        guard let anim = agentAnim else { return }
        mode = .held(until: nil)
        player.flipped = false
        position.y = floorWy
        player.play(anim)
    }

    private func pickNext(now: Double) {
        guard wander else { enterStanding(now: now); return }
        let r = Double.random(in: 0..<1, using: &rng)
        let here = clampX(position.x, bounds(of: "idle_stand"))
        switch r {
        case ..<0.35:    // marche
            let range = walkBounds
            var target = CGFloat.random(in: minWx(range)...max(minWx(range), maxWx(range)), using: &rng)
            if abs(target - here) < 90 { target = clampX(here + (target < here ? -1 : 1) * 160, range) }
            mode = .walking(targetX: target)
        case ..<0.52:    // saut
            let dx = CGFloat.random(in: 120...420, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            let target = clampX(here + dx, bounds(of: "idle_stand"))
            mode = .launching(targetX: target)
            player.flipped = false
            player.play("jump_launch")
        case ..<0.68:    // escalade
            mode = .toWall((here - world.minX) < (world.maxX - here) ? .left : .right)
        case ..<0.82:    // petit mouvement sur place
            mode = .standing(until: now + 4)
            player.flipped = false
            player.play("idle_fidget")
        default:
            enterStanding(now: now)
        }
    }

    /// Fait avancer la fenêtre vers `target` (x de la fenêtre) ; `arrived` quand elle y est.
    private func walk(toward target: CGFloat, dt: CGFloat, now: Double, arrived: () -> Void) {
        let dx = target - position.x
        let step = config.walkSpeed * dt
        player.flipped = false
        player.ensure(dx < 0 ? "walk_left" : "walk_right")
        if abs(dx) <= step { position.x = target; arrived(); return }
        position.x += (dx < 0 ? -1 : 1) * step
        position.y = floorWy
        position.x = clampX(position.x, walkBounds)
    }

    private func startClimb(_ side: Side, now: Double) {
        player.flipped = side == .right
        player.play("climb")
        let r = currentBounds
        position.x = side == .left ? minWx(r) : maxWx(r)
        position.y = min(floorWy, ceilingWy(r))   // à très grande taille, la pose de grimpe ne tient pas depuis le sol
        let top = ceilingWy(climbBounds)
        let thenCeiling = Double.random(in: 0..<1, using: &rng) < 0.6
        let stop = thenCeiling ? top : position.y + (top - position.y) * CGFloat.random(in: 0.35...0.85, using: &rng)
        mode = .climbing(side, stopWy: stop, thenCeiling: thenCeiling)
    }

    private func climb(_ side: Side, stopWy: CGFloat, thenCeiling: Bool, dt: CGFloat, now: Double) {
        let r = currentBounds
        position.x = side == .left ? minWx(r) : maxWx(r)   // la pose change à chaque image : on recolle au mur
        position.y += config.climbSpeed * dt
        position.y = min(position.y, ceilingWy(r))   // garantie : jamais au-dessus de la zone, quelle que soit l'image
        guard position.y >= stopWy else { return }
        if thenCeiling { startCeiling(from: side, now: now) } else { startFall(now: now) }
    }

    private func startCeiling(from side: Side, now: Double) {
        player.flipped = false
        player.play("ceiling")
        let r = currentBounds
        position.y = ceilingWy(r)
        let margin: CGFloat = 30
        position.x = side == .left ? minWx(r) + margin : maxWx(r) - margin
        let dir: CGFloat = side == .left ? 1 : -1
        let distance = CGFloat.random(in: 200...650, using: &rng)
        mode = .ceiling(dir: dir, targetX: clampX(position.x + dir * distance, r))
    }

    private func crawl(dir: CGFloat, target: CGFloat, dt: CGFloat, now: Double) {
        let r = currentBounds
        position.y = ceilingWy(r)
        let step = config.ceilingSpeed * dt
        if abs(target - position.x) <= step { position.x = target; startFall(now: now); return }
        position.x += dir * step
        position.x = clampX(position.x, r)
    }

    private func startFall(now: Double, vx: CGFloat = 0, vy: CGFloat = 0) {
        player.flipped = false
        mode = .air(vx: vx, vy: vy, jump: false)
        player.play("fall")
    }

    /// Vol libre : gravité, rebonds sur les bords, atterrissage selon la vitesse d'impact.
    private func fly(vx: CGFloat, vy: CGFloat, jump: Bool, dt: CGFloat, now: Double) {
        var vx = vx, vy = vy - config.gravity * dt
        position.x += vx * dt
        position.y += vy * dt
        let r = currentBounds
        if position.x < minWx(r) { position.x = minWx(r); vx = abs(vx) * config.restitution }
        if position.x > maxWx(r) { position.x = maxWx(r); vx = -abs(vx) * config.restitution }
        if position.y > ceilingWy(r) { position.y = ceilingWy(r); vy = -abs(vy) * config.restitution }
        let bottom = position.y + size * (1 - r.maxY)
        if bottom <= world.minY, vy <= 0 {
            land(impact: abs(vy), jump: jump, now: now)
            return
        }
        mode = .air(vx: vx, vy: vy, jump: jump)
    }

    private func land(impact: CGFloat, jump: Bool, now: Double) {
        player.flipped = false
        let anim = jump || impact < 900 ? "land_good" : impact < 1600 ? "land_hard" : "land_flop"
        mode = .landing
        position.y = floorWy
        position.x = clampX(position.x, bounds(of: "idle_stand"))
        player.play(anim)
    }

    private func animationEnded(_ name: String, now: Double) {
        switch (mode, name) {
        case (.launching(let target), "jump_launch"):
            let flight = 2 * config.jumpSpeed / config.gravity
            mode = .air(vx: (target - position.x) / flight, vy: config.jumpSpeed, jump: true)
        case (.landing, _) where name.hasPrefix("land_"):
            if agentAnim != nil { enterHeld(now: now) } else { enterStanding(now: now) }
        case (.held(nil), _):
            // Réaction d'agent non bouclée : si le pack enchaîne sur une autre animation d'agent (oops, helper,
            // grateful → working), on y reste ; sinon (célébration…) retour à la vie normale.
            guard name == agentAnim, let anim = player.currentAnimation, !anim.loop else { break }
            if let next = anim.next, next != "idle" { agentAnim = next }
            else { agentAnim = nil; enterStanding(now: now) }
        default: break
        }
    }

    // MARK: - Entrées extérieures

    /// Animation d'état d'agent (nil : retour au repos).
    func agentState(_ anim: String?, now: Double) {
        agentAnim = anim
        if anim != nil { lastActivity = now }
        switch mode {
        case .held(nil) where anim != nil: if let anim { player.flipped = false; player.play(anim) }
        case .held(nil): enterStanding(now: now)
        case .sleeping where anim == nil: break
        default: break   // le tick prend la main (au sol, tout de suite ; en l'air, après l'atterrissage)
        }
    }

    /// Joue une animation pendant quelques secondes (menu « Animations »).
    func demo(_ anim: String, now: Double) {
        agentAnim = nil
        lastActivity = now
        mode = .held(until: now + 4)
        player.flipped = false
        player.play(anim)
    }

    func worldChanged(_ rect: NSRect, now: Double) {
        world = rect
        if case .dragging = mode { return }
        if case .air = mode { return }
        // Le personnage retombe depuis l'endroit où il se trouve, dans le nouveau cadre.
        position.x = clampX(position.x, currentBounds)
        startFall(now: now)
    }

    // MARK: - Souris

    /// Saisie : le personnage pend par la tête au pointeur.
    func beginDrag(at p: CGPoint, now: Double) {
        mode = .dragging
        lastActivity = now
        samples = [(now, p)]
        lastPointer = p
        dragSwing = 0
        player.flipped = false
        player.play("drag")
        place(hangingFrom: p)
    }

    func dragMoved(to p: CGPoint, now: Double) {
        guard case .dragging = mode else { return }
        samples.append((now, p))
        lastPointer = p
        updateDragPose(now: now)
    }

    /// Pose du glisser selon le sens du déplacement. `drag_left` / `drag_right` montrent le personnage tiré vers la
    /// gauche / la droite (il traîne derrière, côté opposé). Seuils différents pour entrer et sortir du balancement,
    /// afin que la pose ne clignote pas autour du seuil.
    private func updateDragPose(now: Double) {
        guard case .dragging = mode else { return }
        samples.removeAll { now - $0.t > 0.12 }
        let vx = velocity().dx
        var swing = dragSwing
        if abs(vx) < 60 { swing = 0 }
        else if vx > 130 { swing = 1 }
        else if vx < -130 { swing = -1 }
        if swing != dragSwing {
            dragSwing = swing
            player.flipped = false
            player.play(swing > 0 ? "drag_right" : swing < 0 ? "drag_left" : "drag")
        }
        place(hangingFrom: lastPointer)   // la pose a pu changer : on recale le haut du personnage sur le pointeur
    }

    /// Relâche : la vitesse du pointeur lance le personnage.
    func endDrag(at p: CGPoint, world newWorld: NSRect, now: Double) {
        guard case .dragging = mode else { return }
        world = newWorld
        let v = velocity()
        let cap = config.maxThrow
        startFall(now: now, vx: min(max(v.dx, -cap), cap), vy: min(max(v.dy, -cap), cap))
        lastActivity = now
    }

    /// Le haut du personnage (là où on le tient) reste sous le pointeur, quelle que soit la pose.
    private func place(hangingFrom p: CGPoint) {
        let pose = player.currentPose
        let r = bounds(of: pose)
        let gx = pack.topCenters[pose] ?? (r.minX + r.width / 2)
        position = CGPoint(x: p.x - gx * size, y: p.y - size * (1 - r.minY))
    }

    private func velocity() -> CGVector {
        guard let first = samples.first, let last = samples.last, last.t - first.t > 0.02 else { return .zero }
        let dt = CGFloat(last.t - first.t)
        return CGVector(dx: (last.p.x - first.p.x) / dt, dy: (last.p.y - first.p.y) / dt)
    }
}
