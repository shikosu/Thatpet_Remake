import AppKit

/// `TPRemake sim` : fait vivre le cerveau du personnage en temps virtuel, sans écran, et vérifie des invariants
/// (le personnage reste dans la zone visible, il ne reste pas bloqué, tous les mouvements sont visités…).
func runSimulation(seconds: Double, seed: UInt64, packs: URL, width: CGFloat = 1440, height: CGFloat = 790, switchTo: URL? = nil, size: CGFloat = 256) -> Int32 {
    let pack: Pack
    do { pack = try Pack.load(from: packs) } catch { print("Erreur : \(error)"); return 1 }
    let world = NSRect(x: 0, y: 80, width: width, height: height)   // par défaut : écran 1440×900 avec Dock et barre des menus
    let player = AnimationPlayer(pack: pack)
    var t = 0.0
    let brain = PetBrain(pack: pack, player: player, size: size, world: world, seed: seed, now: t)
    brain.config.sleepAfter = .infinity   // on veut voir bouger, pas dormir
    var failures: [String] = []

    var timeIn: [String: Double] = [:]
    var entered: [String: Int] = [:]
    var last = brain.mode.name
    var since = 0.0
    var longest: [String: Double] = [:]
    var maxFall: CGFloat = 0
    /// Écart maximal entre le personnage et la surface qu'il est censé toucher, par mode.
    var gap: [String: CGFloat] = [:]

    func check(_ label: String) {
        let f = brain.figure
        let tol: CGFloat = 1.5
        if brain.mode.name != "dragging", f.minX < world.minX - tol || f.maxX > world.maxX + tol
            || f.minY < world.minY - tol || f.maxY > world.maxY + tol {
            failures.append(String(format: "t=%.1f %@ (%@, pose %@) hors de la zone : %@ (zone %@)", t, label, String(describing: brain.mode), player.currentPose, NSStringFromRect(f), NSStringFromRect(world)))
        }
        let f2 = brain.figure
        switch brain.mode.name {
        case "standing", "walking", "toWall", "landing", "held", "sleeping", "launching":
            gap[brain.mode.name, default: 0] = max(gap[brain.mode.name] ?? 0, abs(f2.minY - world.minY))
        case "climbing":
            gap["climbing", default: 0] = max(gap["climbing"] ?? 0, min(abs(f2.minX - world.minX), abs(world.maxX - f2.maxX)))
        case "ceiling":
            gap["ceiling", default: 0] = max(gap["ceiling"] ?? 0, abs(world.maxY - f2.maxY))
        default: break
        }
        if !brain.position.x.isFinite || !brain.position.y.isFinite { failures.append("t=\(t) position non finie") }
    }

    func step(_ dt: Double = 1.0 / 60) {
        t += dt
        brain.tick(now: t)
        let name = brain.mode.name
        timeIn[name, default: 0] += dt
        if name != last {
            longest[last] = max(longest[last] ?? 0, t - since)
            entered[name, default: 0] += 1
            last = name
            since = t
        }
        check("sim")
    }

    // 1. Vie libre
    while t < seconds { step() }
    longest[last] = max(longest[last] ?? 0, t - since)

    print(String(format: "Simulation de %.0f s (graine %llu), zone %@", seconds, seed, NSStringFromRect(world)))
    for name in timeIn.keys.sorted() {
        print(String(format: "  %-10@ %7.1f s   %3d entrée(s)   plus long séjour %5.1f s", name as NSString, timeIn[name]!, entered[name] ?? 0, longest[name] ?? 0))
    }
    print("Écart maximal au point de contact (pt) :", gap.keys.sorted().map { "\($0)=\(String(format: "%.1f", gap[$0]!))" }.joined(separator: "  "))
    for (mode, g) in gap where g > (mode == "climbing" || mode == "ceiling" ? 2 : 15) { failures.append("contact : « \(mode) » flotte à \(String(format: "%.1f", g)) pt de sa surface") }
    for required in ["walking", "toWall", "climbing", "ceiling", "launching", "air", "landing"] where (entered[required] ?? 0) == 0 && seconds >= 600 {
        failures.append("mouvement jamais exécuté : \(required)")
    }
    for (name, d) in longest where !["standing", "sleeping", "held"].contains(name) && d > 60 {
        failures.append("bloqué \(String(format: "%.0f", d)) s dans « \(name) »")
    }

    // 2. Lancer : saisie, glissement rapide vers la droite et le haut, relâchement
    brain.agentState(nil, now: t)
    brain.wander = false   // pour juger l'atterrissage sans que le personnage ne re-saute de lui-même
    for _ in 0..<600 where brain.mode.name != "standing" { step() }
    // (a) Le sens du balancement doit suivre le déplacement ; (b) le haut du personnage reste sous le pointeur
    brain.beginDrag(at: CGPoint(x: 600, y: 500), now: t)
    var px: CGFloat = 600
    func dragPhase(_ label: String, speed: CGFloat, frames: Int, expect: String) {
        for _ in 0..<frames {
            px += speed / 60
            step(); brain.dragMoved(to: CGPoint(x: px, y: 500), now: t)
            let f = brain.figure
            if abs(f.maxY - 500) > 1.5 { failures.append("glisser (\(label)) : le haut du personnage n'est pas sous le pointeur (\(f.maxY))") ; break }
        }
        print("  glisser \(label) : animation « \(player.current) » (attendu « \(expect) »)")
        if player.current != expect { failures.append("glisser \(label) : « \(player.current) » au lieu de « \(expect) »") }
    }
    print("Glisser :")
    dragPhase("vers la droite, vite", speed: 500, frames: 30, expect: "drag_right")
    dragPhase("vers la gauche, vite", speed: -500, frames: 30, expect: "drag_left")
    dragPhase("vers la droite, doucement", speed: 200, frames: 30, expect: "drag_right")
    dragPhase("quasi à l'arrêt", speed: 20, frames: 30, expect: "drag")
    for _ in 0..<30 { step() }   // pointeur immobile, plus aucun évènement
    if player.current != "drag" { failures.append("glisser : balancement non retiré à l'arrêt (\(player.current))") }
    dragPhase("vers la droite, vite", speed: 500, frames: 30, expect: "drag_right")
    for _ in 0..<30 { step() }
    print("  pointeur immobile : animation « \(player.current) » (attendu « drag »)")
    if player.current != "drag" { failures.append("glisser : balancement figé quand la souris s'arrête (\(player.current))") }
    brain.endDrag(at: CGPoint(x: px, y: 500), world: world, now: t)
    for _ in 0..<600 where brain.mode.name != "standing" { step() }
    brain.agentState(nil, now: t)

    brain.beginDrag(at: CGPoint(x: 400, y: 300), now: t)
    for i in 1...12 { step(); brain.dragMoved(to: CGPoint(x: 400 + CGFloat(i) * 60, y: 300 + CGFloat(i) * 30), now: t) }
    step(); brain.endDrag(at: CGPoint(x: 1120, y: 660), world: world, now: t)
    var airborne = 0.0
    while brain.mode.name == "air" && airborne < 10 { step(); airborne += 1.0 / 60; maxFall = max(maxFall, brain.figure.maxY) }
    print(String(format: "Lancer : %.2f s en l'air, point le plus haut %.0f, atterrit en « %@ » (%@)", airborne, maxFall, brain.mode.name, player.current))
    if airborne >= 10 { failures.append("lancer : ne retombe jamais") }
    if brain.mode.name != "landing" { failures.append("lancer : n'atterrit pas") }
    for _ in 0..<240 { step() }
    if brain.mode.name != "standing" { failures.append("après atterrissage : \(brain.mode.name) au lieu de standing") }
    if abs(brain.figure.minY - world.minY) > 12 { failures.append("après atterrissage : pas au sol (bas à \(brain.figure.minY))") }

    brain.wander = true

    // 3. Lancer extrême (vitesse plafonnée) vers un coin
    brain.beginDrag(at: CGPoint(x: 700, y: 500), now: t)
    step(); brain.dragMoved(to: CGPoint(x: 1400, y: 880), now: t)
    step(1.0 / 60); brain.endDrag(at: CGPoint(x: 1400, y: 880), world: world, now: t)
    for _ in 0..<1200 { step() }
    print("Lancer extrême : état final « \(brain.mode.name) »")
    if !["standing", "walking", "toWall", "launching", "climbing", "ceiling", "air", "landing"].contains(brain.mode.name) { failures.append("lancer extrême : état inattendu") }

    // 4. Réaction à un agent pendant une escalade
    var guardLoop = 0
    while brain.mode.name != "climbing" && guardLoop < 60 * 600 { step(); guardLoop += 1 }
    if brain.mode.name == "climbing" {
        for _ in 0..<60 { step() }
        brain.agentState("thinking", now: t)
        var steps = 0
        while brain.mode.name != "held" && steps < 60 * 15 { step(); steps += 1 }
        print(String(format: "Agent pendant l'escalade : réagit en « %@ » après %.1f s (animation %@)", brain.mode.name, Double(steps) / 60, player.current))
        if brain.mode.name != "held" || player.current != "thinking" { failures.append("agent : pas de réaction (mode \(brain.mode.name), anim \(player.current))") }
        if abs(brain.figure.minY - world.minY) > 12 { failures.append("agent : pas redescendu au sol") }
        brain.agentState(nil, now: t)
        for _ in 0..<10 { step() }
        if brain.mode.name != "standing" { failures.append("agent terminé : \(brain.mode.name) au lieu de standing") }
    } else {
        failures.append("agent : aucune escalade trouvée pour le test")
    }

    // 5. Interaction (bulle ouverte) : le personnage doit rester en place
    var holding = true
    brain.hold = { holding }
    for _ in 0..<60 { step() }
    let held = brain.position
    for _ in 0..<(60 * 40) { step() }
    if brain.position != held { failures.append("hold : le personnage a bougé pendant l'interaction") }
    holding = false

    // 5b. Survol : le personnage qui marche s'arrête sous le pointeur, puis repart ; sur un mur il ne tombe pas
    var wait2 = 0
    while brain.mode.name != "walking" && wait2 < 60 * 600 { step(); wait2 += 1 }
    if brain.mode.name == "walking" {
        brain.hover = true
        for _ in 0..<3 { step() }
        let still = brain.position
        for _ in 0..<180 { step() }
        if brain.position != still || brain.mode.name != "walking" { failures.append("survol : le personnage marche encore sous le pointeur") }
        if !player.paused { failures.append("survol : animation non figée") }
        brain.hover = false
        for _ in 0..<60 { step() }
        if brain.position == still { failures.append("survol : ne repart pas après le survol") }
        if player.paused { failures.append("survol : animation restée figée") }
    } else { failures.append("survol : aucune marche trouvée pour le test") }
    wait2 = 0
    while brain.mode.name != "climbing" && wait2 < 60 * 900 { step(); wait2 += 1 }
    if brain.mode.name == "climbing" {
        for _ in 0..<30 { step() }
        holding = true
        for _ in 0..<3 { step() }
        let onWall = brain.position
        for _ in 0..<(60 * 20) { step() }
        if brain.mode.name != "climbing" || brain.position != onWall { failures.append("interaction sur le mur : le personnage a bougé ou est tombé (\(brain.mode.name))") }
        holding = false
        for _ in 0..<60 { step() }
        if brain.position == onWall { failures.append("interaction sur le mur : ne reprend pas l'escalade") }
    } else { failures.append("interaction sur le mur : aucune escalade trouvée") }

    // 5c. Enchaînements du pack : oops / helper / grateful → working (on reste « au travail »), célébration → vie normale
    for anim in ["oops", "helper", "grateful", "celebrating"] {
        brain.wander = false
        for _ in 0..<600 where brain.mode.name != "standing" { step() }
        brain.agentState(anim, now: t)
        var n = 0
        while player.current != anim && n < 120 { step(); n += 1 }
        n = 0
        while player.current == anim && n < 60 * 6 { step(); n += 1 }
        let chain = anim == "celebrating" ? "standing" : "held"
        for _ in 0..<(60 * 3) { step() }
        print("  enchaînement « \(anim) » : mode « \(brain.mode.name) », animation « \(player.current) »")
        if anim != "celebrating", (brain.mode.name != chain || player.current != "working") { failures.append("enchaînement \(anim) : mode \(brain.mode.name), animation \(player.current) (attendu held / working)") }
        if anim == "celebrating", brain.mode.name != chain { failures.append("célébration : mode \(brain.mode.name) au lieu de standing") }
        brain.agentState(nil, now: t)
        for _ in 0..<60 { step() }
        if brain.mode.name != "standing" { failures.append("après \(anim) : mode \(brain.mode.name) au lieu de standing") }
    }
    brain.wander = true

    // 6. Changement de personnage en pleine escalade
    if let switchTo, let other = try? Pack.load(from: switchTo) {
        var wait = 0
        while brain.mode.name != "climbing" && wait < 60 * 600 { step(); wait += 1 }
        if brain.mode.name == "climbing" {
            for _ in 0..<45 { step() }
            brain.replacePack(other, now: t)
            print("Changement de personnage en escalade : « \(brain.pack.id) », état « \(brain.mode.name) »")
            if brain.pack.id != other.id { failures.append("changement de personnage : pack inchangé") }
            for _ in 0..<(60 * 600) { step() }
            let f = brain.figure
            if f.minX < world.minX - 1.5 || f.maxX > world.maxX + 1.5 { failures.append("changement de personnage : hors zone ensuite") }
        } else { failures.append("changement de personnage : aucune escalade trouvée") }
    }

    // 6b. Changement de taille en pleine escalade, puis au sol : toujours au sol, dans la zone, et la physique suit
    do {
        var wait = 0
        while brain.mode.name != "climbing" && wait < 60 * 600 { step(); wait += 1 }
        for newSize in [min(size * 2, brain.maxCanvas), size / 2, size] {
            if brain.mode.name == "climbing" { for _ in 0..<30 { step() } }
            brain.resize(to: newSize, now: t)
            let f = brain.figure
            print(String(format: "Taille %.0f pt : état « %@ », personnage %.0f × %.0f pt, bas à %.1f", newSize, brain.mode.name as NSString, f.width, f.height, f.minY))
            if brain.size != newSize { failures.append("taille : non appliquée") }
            if f.minX < world.minX - 1.5 || f.maxX > world.maxX + 1.5 || f.maxY > world.maxY + 1.5 || f.minY < world.minY - 1.5 {
                failures.append("taille \(newSize) : hors zone juste après le changement \(NSStringFromRect(f))")
            }
            if abs(f.minY - world.minY) > 1.5 { failures.append("taille \(newSize) : pas posé au sol après le changement") }
            for _ in 0..<(60 * 240) { step() }
            wait = 0
            while brain.mode.name != "climbing" && wait < 60 * 300 { step(); wait += 1 }
        }
    }

    // 7. Les extrêmes de la zone sont atteignables (murs et plafond)
    if failures.isEmpty { print("OK : aucun défaut détecté") } else {
        print("\(failures.count) défaut(s) :")
        for f in failures.prefix(15) { print("  - \(f)") }
    }
    return failures.isEmpty ? 0 : 1
}

/// `TPRemake fx-test` : vérifie chaque effet de mouvement contre les valeurs relevées dans l'original.
func runFxTests() -> Int32 {
    var failures: [String] = []
    var checks = 0
    func near(_ label: String, _ value: CGFloat, _ expected: Double, tol: Double = 0.002) {
        checks += 1
        if abs(Double(value) - expected) > tol { failures.append("\(label) : \(value) au lieu de \(expected)") }
    }
    func eval(_ fx: String, t: Double = 0, frameT: Double = 0, frameDur: Double = 0.15, unit: Double = 1, vx: Double = 0, vy: Double = 0,
              spin: (Double, Double)? = nil) -> PetTransform {
        var pendulum = PendulumState()
        var input = FxInput(t: t, frameT: frameT, frameDur: frameDur, unit: unit, vx: vx, vy: vy, jumpSpeed: 900)
        if let spin { input.spin = (spin.0, spin.1) }
        return Fx.evaluate([fx], input, pendulum: &pendulum)
    }

    // land_squash : écrasé de 20 % à l'impact (largeur ×0,8^-0,75), rebond puis retour à 1
    let l0 = eval("land_squash", t: 0)
    near("land_squash t=0 sy", l0.sy, 0.8); near("land_squash t=0 sx", l0.sx, pow(0.8, -0.75))
    let l1 = eval("land_squash", t: 2)
    near("land_squash t=2 sy", l1.sy, 1, tol: 0.001); near("land_squash t=2 sx", l1.sx, 1, tol: 0.001)
    var peak = 0.0
    for i in 0..<200 { peak = max(peak, Double(eval("land_squash", t: Double(i) / 100).sy)) }
    checks += 1; if peak <= 1.0 { failures.append("land_squash : pas de rebond (sy max \(peak))") }

    // squash : crête ×1,12 / ×0,86 à la fin de l'image ; stretch et fall_stretch selon la vitesse
    let sq = eval("squash", frameT: 0.18, frameDur: 0.18); near("squash sx", sq.sx, 1.12); near("squash sy", sq.sy, 0.86)
    let sq0 = eval("squash", frameT: 0, frameDur: 0.18); near("squash début", sq0.sy, 1)
    let st = eval("stretch", vy: 900); near("stretch sx", st.sx, 0.92); near("stretch sy", st.sy, 1.10)
    let fs = eval("fall_stretch", vy: -6000); near("fall_stretch sy", fs.sy, 1.12); near("fall_stretch sx", fs.sx, 1 / 1.12)
    let fs2 = eval("fall_stretch", vy: -60000); near("fall_stretch plafonné", fs2.sy, 1.12)
    let fs3 = eval("fall_stretch", vy: 500); near("fall_stretch en montée", fs3.sy, 1)

    // hop : arc de 10 unités en 0,22 s
    near("hop milieu", eval("hop", frameT: 0.11, unit: 1.6).dy, 16)
    near("hop fin", eval("hop", frameT: 0.22, unit: 1.6).dy, 0)
    near("hop début", eval("hop", frameT: 0, unit: 1.6).dy, 0)

    // shake_once : 12 Hz amorti, nul après 0,5 s
    var maxShake = 0.0, lastHalf = 0.0
    for i in 0..<500 { let t = Double(i) / 1000; let d = abs(Double(eval("shake_once", t: t, unit: 1).dx)); if t < 0.1 { maxShake = max(maxShake, d) }; if t > 0.4 { lastHalf = max(lastHalf, d) } }
    checks += 1; if maxShake < 3 || maxShake > 6 { failures.append("shake_once : amplitude initiale \(maxShake)") }
    checks += 1; if lastHalf >= maxShake / 3 { failures.append("shake_once : ne s'amortit pas (\(lastHalf) vs \(maxShake))") }
    near("shake_once après 0,5 s", eval("shake_once", t: 0.6, unit: 1).dx, 0)

    // poof : 60 % de taille et 40 % d'opacité à 0,16 s, retour complet à 0,38 s
    let p0 = eval("poof", t: 0); near("poof début alpha", p0.alpha, 1); near("poof début sx", p0.sx, 1)
    let p1 = eval("poof", t: 0.16); near("poof creux alpha", p1.alpha, 0.4); near("poof creux sx", p1.sx, 0.6)
    let p2 = eval("poof", t: 0.38); near("poof fin alpha", p2.alpha, 1); near("poof fin sx", p2.sx, 1)

    // spin_hop : 14 unités au milieu de la plage des images « spin »
    near("spin_hop milieu", eval("spin_hop", t: 0.285, unit: 1, spin: (0.12, 0.45)).dy, 14, tol: 0.1)
    near("spin_hop avant", eval("spin_hop", t: 0.05, unit: 1, spin: (0.12, 0.45)).dy, 0)
    near("spin_hop sans plage", eval("spin_hop", t: 0.285, unit: 1).dy, 0)

    // sway, breathe, bobs
    var swayMax = 0.0, breatheMax = 0.0, walkMin = 99.0, walkMax = -99.0, typeMax = 0.0
    for i in 0..<2000 {
        let t = Double(i) / 100
        swayMax = max(swayMax, abs(Double(eval("sway", t: t).rotation)))
        breatheMax = max(breatheMax, Double(eval("breathe", t: t).sy))
        let w = Double(eval("walk_bob", t: t, frameDur: 0.15, unit: 1).dy); walkMin = min(walkMin, w); walkMax = max(walkMax, w)
        typeMax = max(typeMax, Double(eval("type_bob", t: t, unit: 1).dy))
    }
    checks += 4
    if abs(swayMax - 0.020944) > 0.0005 { failures.append("sway : amplitude \(swayMax)") }
    if abs(breatheMax - 1.012) > 0.0005 { failures.append("breathe : crête \(breatheMax)") }
    if walkMin < -0.001 || abs(walkMax - 3) > 0.01 { failures.append("walk_bob : plage [\(walkMin), \(walkMax)]") }
    if abs(typeMax - 1.5) > 0.01 { failures.append("type_bob : crête \(typeMax)") }
    let period = 25.0 / 7.0
    near("breathe périodique", eval("breathe", t: period).sy, Double(eval("breathe", t: 0).sy), tol: 1e-6)

    // pendule : tiré vers la droite à 560 pt/s → cible −14° (borne) ; à l'arrêt il revient vers 0 sans dépasser ±14°
    var pend = PendulumState()
    var overshoot = 0.0
    var t = 0.0
    while t < 3 { t += 1.0 / 60; pend.step(target: -560 / 40, t: t); overshoot = max(overshoot, abs(pend.theta)) }
    checks += 3
    if abs(pend.theta + 14) > 0.5 { failures.append("pendule : \(pend.theta)° au lieu de −14°") }
    if overshoot > 14.0001 { failures.append("pendule : dépasse la borne (\(overshoot)°)") }
    while t < 6 { t += 1.0 / 60; pend.step(target: 0, t: t) }
    if abs(pend.theta) > 0.5 { failures.append("pendule : ne revient pas à 0 (\(pend.theta)°)") }
    var pend2 = PendulumState(); var swung = false; t = 0
    while t < 1 { t += 1.0 / 60; pend2.step(target: -10, t: t); if pend2.theta < -10.5 { swung = true } }
    checks += 1; if !swung { failures.append("pendule : pas d'oscillation (trop amorti)") }

    // un effet inconnu ne fait rien ; cumul de plusieurs effets
    var pendulum = PendulumState()
    let combo = Fx.evaluate(["breathe", "inconnu", "sway"], FxInput(t: 1), pendulum: &pendulum)
    checks += 1; if combo.sy == 1 || combo.rotation == 0 { failures.append("cumul d'effets : \(combo)") }

    print("\(checks) vérifications, \(failures.count) échec(s)")
    for f in failures { print("  - \(f)") }
    return failures.isEmpty ? 0 : 1
}

/// `TPRemake particles-test` : vérifie la logique des particules (sans écran).
func runParticleTests(packs: URL) -> Int32 {
    var failures: [String] = []
    var checks = 0
    func check(_ ok: Bool, _ label: @autoclosure () -> String) { checks += 1; if !ok { failures.append(label()) } }
    let frame = ParticleSystem.Frame(figure: CGRect(x: 100, y: 20, width: 110, height: 250), floorY: 20, unit: 1.6)
    func fresh(_ names: [String], seed: UInt64 = 7) -> ParticleSystem {
        let s = ParticleSystem(seed: seed); s.animationStarted(particles: names, now: 0, frame: frame); return s
    }
    func sane(_ sprites: [ParticleSprite], _ label: String) {
        for s in sprites {
            check(s.position.x.isFinite && s.position.y.isFinite && s.size.isFinite && s.size >= 0, "\(label) : valeur invalide \(s.position) taille \(s.size)")
            check(s.alpha >= 0 && s.alpha <= 1.0001, "\(label) : opacité hors [0,1] (\(s.alpha))")
        }
    }

    // Les noms d'effets du pack sont tous connus du système de particules
    if let pack = try? Pack.load(from: packs) {
        let declared = Set(pack.animations.values.flatMap { $0.particles })
        for name in declared { check(ParticleSystem.periodicNames.contains(name) || ParticleSystem.burstNames.contains(name), "effet de particules inconnu : \(name)") }
        print("Effets déclarés par le pack : \(declared.sorted().joined(separator: ", "))")
    }

    // Rafales : naissent, restent saines, meurent toutes
    let expected: [String: Int] = ["confetti": 32, "sparkle_small": 6, "sparkle": 10, "hearts": 6, "sweat": 4, "poof": 10, "dust": 8]
    for (name, count) in expected.sorted(by: { $0.key < $1.key }) {
        let s = fresh([name])
        check(s.aliveBursts == count, "\(name) : \(s.aliveBursts) particules au lieu de \(count)")
        var seen = 0
        for i in 0...300 { let sp = s.sprites(now: Double(i) / 100, frame: frame); seen = max(seen, sp.count); sane(sp, name) }
        check(seen > 0, "\(name) : jamais visible")
        check(s.sprites(now: 5, frame: frame).isEmpty && s.aliveBursts == 0, "\(name) : particules encore vivantes après 5 s")
    }

    // Confettis : montent puis retombent (gravité), restent près du personnage
    let c = fresh(["confetti"])
    func meanY(_ sp: [ParticleSprite]) -> CGFloat { sp.map { $0.position.y }.reduce(0, +) / CGFloat(max(sp.count, 1)) }
    let early = meanY(c.sprites(now: 0.25, frame: frame)), late = meanY(c.sprites(now: 1.2, frame: frame))
    check(late < early, "confetti : ne retombent pas (\(early) → \(late))")
    check(c.sprites(now: 0.3, frame: frame).allSatisfy { abs($0.position.x - 155) < 400 }, "confetti : trop loin du personnage")
    check(c.sprites(now: 0.3, frame: frame).contains { $0.scaleX < 0.95 }, "confetti : pas de « flutter »")

    // Sueur : les gouttes finissent par tomber
    let sw = fresh(["sweat"])
    let a = sw.sprites(now: 0.3, frame: frame), b = sw.sprites(now: 0.6, frame: frame)
    check(!a.isEmpty && meanY(b) < meanY(a), "sweat : les gouttes ne tombent pas")

    // Cœurs : pas avant 0,45 s, puis montent en grossissant
    let h = fresh(["hearts"])
    check(h.sprites(now: 0.2, frame: frame).isEmpty, "hearts : visibles avant leur délai")
    let h1 = h.sprites(now: 0.95, frame: frame), h2 = h.sprites(now: 1.4, frame: frame)
    check(h1.count == 6 && meanY(h2) > meanY(h1), "hearts : ne montent pas")
    check((h2.map { $0.size }.reduce(0, +) / CGFloat(max(h2.count, 1))) > (h1.map { $0.size }.reduce(0, +) / CGFloat(max(h1.count, 1))) * 0.9, "hearts : ne grossissent pas")

    // Poussière : près du sol, s'élargit ; nuage : s'étend autour du personnage
    let d = fresh(["dust"])
    check(d.sprites(now: 0.05, frame: frame).allSatisfy { abs($0.position.y - 22) < 15 }, "dust : pas au niveau du sol")
    let d1 = d.sprites(now: 0.1, frame: frame), d2 = d.sprites(now: 0.4, frame: frame)
    check(d1.map { $0.size }.reduce(0, +) < d2.map { $0.size }.reduce(0, +), "dust : ne s'étend pas")

    // Périodiques : nombre de « z » croissant puis stable, répétition exacte à chaque période
    let z = fresh(["zzz"])
    check(z.sprites(now: 0.3, frame: frame).count == 1, "zzz : 1 « z » attendu à 0,3 s")
    check(z.sprites(now: 0.9, frame: frame).count == 2, "zzz : 2 « z » attendus à 0,9 s")
    check(z.sprites(now: 1.5, frame: frame).count == 3, "zzz : 3 « z » attendus à 1,5 s")
    let z1 = z.sprites(now: 2.0, frame: frame), z2 = z.sprites(now: 3.8, frame: frame)
    func same(_ a: [CGFloat], _ b: [CGFloat]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 } }
    check(z1.count == 3 && same(z1.map { $0.position.y }, z2.map { $0.position.y }), "zzz : pas périodique (1,8 s)")
    check(z.sprites(now: 2.0, frame: frame).allSatisfy { $0.position.y > 270 && $0.position.x > 155 }, "zzz : pas au-dessus et à droite de la tête")
    let t = fresh(["thought_dots"])
    check(t.sprites(now: 0.05, frame: frame).count == 1 && t.sprites(now: 0.5, frame: frame).count == 3, "thought_dots : apparition 1 → 3 points")
    check(same(t.sprites(now: 0.5, frame: frame).map { $0.size }, t.sprites(now: 1.7, frame: frame).map { $0.size }), "thought_dots : pas périodique (1,2 s)")
    let e = fresh(["exclaim"])
    check(e.sprites(now: 0.2, frame: frame).count == 1 && e.sprites(now: 5.1, frame: frame).count == 1, "exclaim : un « ! » en permanence")
    sane(e.sprites(now: 0.1, frame: frame) + t.sprites(now: 0.6, frame: frame) + z.sprites(now: 1.0, frame: frame), "périodiques")

    // Une nouvelle animation arrête les effets continus de la précédente
    let m = fresh(["zzz"]); m.animationStarted(particles: ["thought_dots"], now: 10, frame: frame)
    check(m.sprites(now: 10.5, frame: frame).allSatisfy { $0.shape == .dot }, "changement d'animation : « z » encore affichés")
    m.animationStarted(particles: [], now: 20, frame: frame)
    check(m.sprites(now: 20.5, frame: frame).isEmpty, "animation sans particules : des sprites restent")

    // Désactivé : rien, et rien n'est mis en file
    let off = ParticleSystem(seed: 1); off.enabled = false
    off.animationStarted(particles: ["confetti", "zzz"], now: 0, frame: frame)
    check(off.sprites(now: 0.3, frame: frame).isEmpty && off.aliveBursts == 0, "désactivé : des particules sont apparues")

    // Déterminisme : même graine, mêmes particules
    let p1 = fresh(["confetti"], seed: 42).sprites(now: 0.5, frame: frame), p2 = fresh(["confetti"], seed: 42).sprites(now: 0.5, frame: frame)
    check(p1.map { $0.position.x } == p2.map { $0.position.x }, "graine : non déterministe")

    // Beaucoup de relances : le nombre de particules reste borné
    let stress = ParticleSystem(seed: 3)
    for i in 0..<400 { stress.animationStarted(particles: ["confetti", "poof", "sweat"], now: Double(i) * 0.05, frame: frame); _ = stress.sprites(now: Double(i) * 0.05, frame: frame) }
    check(stress.aliveBursts < 1500, "relances : \(stress.aliveBursts) particules vivantes (fuite ?)")

    print("\(checks) vérifications, \(failures.count) échec(s)")
    for f in failures.prefix(20) { print("  - \(f)") }
    return failures.isEmpty ? 0 : 1
}


/// `TPRemake reactions-test` : moteur de réactions (états, escalade d'attention, merci, surprise rare) et textes de la bulle.
func runReactionTests(packs: URL) -> Int32 {
    guard let pack = try? Pack.load(from: packs) else { print("pack illisible"); return 1 }
    var failures: [String] = []
    var checks = 0
    func check(_ ok: Bool, _ label: @autoclosure () -> String) { checks += 1; if !ok { failures.append(label()) } }
    let has: (String) -> Bool = { pack.animations[$0] != nil }
    func engine(seed: UInt64 = 1) -> ReactionEngine { ReactionEngine(seed: seed) }

    // Table des états
    let table: [(String, String?)] = [("idle", nil), ("stop", nil), ("thinking", "thinking"), ("working", "working"), ("attention", "attention"),
                                      ("helper", "helper"), ("toolfail", "oops"), ("compacting", "compacting"), ("error", "error")]
    for (state, anim) in table {
        let r = engine().react(to: state, now: 0, has: has)
        check(r.change == .play(anim), "état \(state) : \(r.change) au lieu de \(String(describing: anim))")
    }
    check(engine().react(to: "inconnu", now: 0, has: has).change == .keep, "état inconnu : doit être ignoré")
    // Animation absente du pack : repli sur idle (jamais de plantage)
    let none: (String) -> Bool = { _ in false }
    check(engine().react(to: "working", now: 0, has: none).change == .play("idle"), "animation absente : pas de repli sur idle")

    // Attention : son à l'arrivée, montée à 30 s, un seul passage « urgent », rappels toutes les 45 s
    let e = engine()
    let a = e.react(to: "attention", now: 100, has: has)
    check(a.change == .play("attention") && a.sounds == ["Tink"], "attention : animation / son initial")
    check(e.tick(now: 129, has: has) == ReactionEngine.Result(change: .keep), "attention : escalade trop tôt (29 s)")
    let u = e.tick(now: 130.5, has: has)
    check(u.change == .play("attention_urgent") && u.sounds == ["Tink"], "attention : pas d'escalade à 30 s (\(u))")
    check(e.tick(now: 131, has: has) == ReactionEngine.Result(change: .keep), "attention : escalade répétée")
    check(e.tick(now: 160, has: has).sounds.isEmpty, "attention : rappel trop tôt")
    check(e.tick(now: 176, has: has).sounds == ["Tink"], "attention : pas de rappel après 45 s")
    check(e.tick(now: 177, has: has).sounds.isEmpty, "attention : rappel répété")
    // Réponse de l'utilisateur : « merci » puis plus d'escalade
    let g = e.react(to: "working", now: 200, has: has)
    check(g.change == .play("grateful") && g.sounds.isEmpty, "après attention : « grateful » attendu (\(g))")
    check(e.tick(now: 400, has: has) == ReactionEngine.Result(change: .keep), "après réponse : escalade encore active")
    check(e.react(to: "working", now: 201, has: has).change == .play("working"), "working suivant : doit rester « working »")
    // Une attention restée sans réponse puis résolue par autre chose que working : pas de merci parasite
    let e2 = engine(); _ = e2.react(to: "attention", now: 0, has: has)
    check(e2.react(to: "thinking", now: 5, has: has).change == .play("thinking"), "attention → thinking")
    check(e2.react(to: "working", now: 6, has: has).change == .play("working"), "merci seulement juste après l'attention")

    // Surprise rare : fréquence ≈ rareChance, jamais deux dans le délai de repos
    var rares = 0
    let r1 = engine(seed: 5); r1.rareChance = 0.1; r1.rareCooldown = 0
    for i in 0..<5000 { if r1.react(to: "celebrating", now: Double(i), has: has).change == .play("rare_surprise") { rares += 1 } }
    check(rares > 380 && rares < 620, "surprise rare : \(rares) sur 5000 (≈10 % attendu)")
    let r2 = engine(seed: 5); r2.rareChance = 1; r2.rareCooldown = 3600
    var cooled = 0
    for i in 0..<50 { if r2.react(to: "celebrating", now: Double(i) * 60, has: has).change == .play("rare_surprise") { cooled += 1 } }
    check(cooled == 1, "délai de repos : \(cooled) surprises en 50 min au lieu de 1")
    let r3 = engine(); r3.rareChance = 1; r3.rareCooldown = 3600
    _ = r3.react(to: "celebrating", now: 0, has: has)
    check(r3.react(to: "celebrating", now: 3601, has: has).change == .play("rare_surprise"), "surprise rare : pas de nouvelle après le délai")
    let r4 = engine(); r4.rareChance = 0
    check((0..<200).allSatisfy { r4.react(to: "celebrating", now: Double($0) * 4000, has: has).change == .play("celebrating") }, "chance 0 : surprise rare apparue")
    let r5 = engine(); r5.rareChance = 1
    check(r5.react(to: "celebrating", now: 0, has: { $0 != "rare_surprise" && has($0) }).change == .play("celebrating"), "sans rare_surprise dans le pack : doit célébrer normalement")

    // Textes de la bulle d'activité
    let texts: [(String?, String, String)] = [
        ("Bash", "working", "Lance une commande"), ("Edit", "working", "Modifie un fichier"), ("MultiEdit", "working", "Modifie un fichier"),
        ("Write", "working", "Modifie un fichier"), ("Read", "working", "Lit un fichier"), ("Grep", "working", "Cherche dans le projet"),
        ("Glob", "working", "Cherche dans le projet"), ("WebFetch", "working", "Navigue sur le web"), ("WebSearch", "working", "Navigue sur le web"),
        ("Task", "working", "Demande à un assistant"), ("TodoWrite", "working", "Planifie"), ("generate_image", "working", "Crée une image"),
        ("mcp__github__create_issue", "working", "Utilise github"), ("Inconnu", "working", "Utilise un outil"),
        (nil, "working", "Travaille sur l'ordinateur"), (nil, "thinking", "Réfléchit…"), (nil, "attention", "A besoin de vous !"),
        (nil, "helper", "Appelle un assistant"), (nil, "celebrating", "Terminé !"), (nil, "idle", ""), (nil, "stop", ""),
    ]
    for (tool, state, expected) in texts {
        let got = AgentEvents.bubbleText(state: state, tool: tool) ?? ""
        check(got == expected, "bulle (\(tool ?? "—"), \(state)) : « \(got) » au lieu de « \(expected) »")
    }

    print("\(checks) vérifications, \(failures.count) échec(s)")
    for f in failures { print("  - \(f)") }
    return failures.isEmpty ? 0 : 1
}
