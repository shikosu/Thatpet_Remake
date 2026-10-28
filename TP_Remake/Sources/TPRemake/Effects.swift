import Foundation

/// Déformation appliquée à l'image : translation (points), rotation (radians, autour du point d'ancrage),
/// échelle et opacité. Résultat cumulé de tous les effets (« fx ») d'une animation.
struct PetTransform {
    var sx: CGFloat = 1
    var sy: CGFloat = 1
    var rotation: CGFloat = 0
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var alpha: CGFloat = 1
}

/// Ressort amorti du pendule : le personnage tenu par la tête se balance selon la vitesse du pointeur.
struct PendulumState {
    var theta: Double = 0      // degrés
    var omega: Double = 0      // degrés / s
    var lastT: Double = 0

    /// Avance jusqu'à `t` vers l'angle cible (borné à ±14°, comme l'original).
    mutating func step(target: Double, t: Double) {
        let dt = min(max(t - lastT, 0), 0.05)
        lastT = t
        guard dt > 0 else { return }
        let goal = min(max(target, -14), 14)
        let w0 = 11.0, zeta = 0.3
        let accel = -w0 * w0 * (theta - goal) - 2 * zeta * w0 * omega
        omega += accel * dt
        theta += omega * dt
        theta = min(max(theta, -14), 14)
    }
}

/// Données nécessaires à l'évaluation des effets à un instant.
struct FxInput {
    var t: Double = 0               // secondes depuis le début de l'animation
    var frameT: Double = 0          // secondes depuis le début de l'image courante
    var frameDur: Double = 0.15     // durée de l'image courante (s)
    var unit: Double = 1            // points par « unité » de conception (= taille appliquée)
    var vx: Double = 0              // vitesse horizontale du personnage / du pointeur (pt/s)
    var vy: Double = 0              // vitesse verticale (pt/s, positive vers le haut)
    var jumpSpeed: Double = 900     // vitesse de référence d'un saut
    var spin: (start: Double, end: Double)? = nil   // plage de temps des images « spin » (spin_hop)
}

/// Effets de mouvement de l'original, d'après les constantes relevées dans le binaire (ThatPetCore.Fx).
enum Fx {
    /// Noms d'effets connus (comme PackLoader.knownFx).
    static let known: Set<String> = ["breathe", "breathe_slow", "sway", "type_bob", "walk_bob", "climb_bob", "pendulum",
                                     "squash", "stretch", "land_squash", "fall_stretch", "hop", "shake_once", "spin_hop", "poof"]

    private static func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    static func evaluate(_ names: [String], _ i: FxInput, pendulum: inout PendulumState) -> PetTransform {
        var out = PetTransform()
        let t = max(i.t, 0)
        let u = i.unit
        func scale(_ sx: Double, _ sy: Double) { out.sx *= CGFloat(sx); out.sy *= CGFloat(sy) }
        for name in names {
            switch name {
            case "breathe":
                let s = sin(t * 1.7592918860102844)            // période 25/7 s
                scale(1 - 0.004 * s, 1 + 0.012 * s)
            case "breathe_slow":
                let s = sin(t * 1.0053096491487339)            // période 6,25 s
                scale(1 - 0.004 * s, 1 + 0.012 * s)
            case "sway":
                out.rotation += CGFloat(sin(t * 1.2566370614359172) * 0.020943951023931952)   // ±1,2°, période 5 s
            case "type_bob":
                out.dy += CGFloat(abs(sin(t * .pi / 0.26)) * 1.5 * u)
            case "walk_bob":
                // Un pas toutes les 0,3 s ; décalé d'une demi-image pour que le rebond tombe sur l'appui du pied.
                let phase = (t - i.frameDur / 2) * .pi / 0.3
                out.dy += CGFloat(abs(sin(phase)) * 3 * u)
            case "climb_bob":
                out.dx += CGFloat(2 * u * sin(2 * .pi * t / 0.52) / 1.6)
            case "pendulum":
                pendulum.step(target: -i.vx / 40, t: t)
                let calm = max(0, 1 - abs(i.vx) / 150)          // petit balancement propre quand on ne bouge pas
                out.rotation += CGFloat((pendulum.theta + sin(t * .pi) * 3 * calm) * .pi / 180)
            case "squash":
                let p = smooth(i.frameT / max(i.frameDur, 0.001))   // s'accroupit pendant l'image
                scale(1 + 0.12 * p, 1 - 0.14 * p)
            case "stretch":
                let p = min(max(i.vy / max(i.jumpSpeed, 1), 0), 1)
                scale(1 - 0.08 * p, 1 + 0.10 * p)
            case "fall_stretch":
                if i.vy < 0 {
                    let k = min(abs(i.vy) / 6000, 0.12)
                    scale(1 / (1 + k), 1 + k)
                }
            case "land_squash":
                // Ressort amorti : écrasé de 20 % à l'impact, rebond, retour ; la largeur compense (volume conservé).
                let y = 1 - 0.2 * exp(-7 * t) * (cos(13.07669683062202 * t) + 0.5353033790313109 * sin(13.07669683062202 * t))
                scale(pow(y, -0.75), y)
            case "hop":
                if i.frameT < 0.22 { out.dy += CGFloat(10 * u * sin(.pi * i.frameT / 0.22)) }
            case "shake_once":
                if t < 0.5 { out.dx += CGFloat(exp(-6 * t) * sin(24 * .pi * t) * 6 * u) }
            case "spin_hop":
                if let span = i.spin, t >= span.start, t < span.end {
                    out.dy += CGFloat(sin(.pi * (t - span.start) / (span.end - span.start)) * 14 * u)
                }
            case "poof":
                // Rétrécit et s'efface (0 → 0,16 s), puis revient (0,16 → 0,38 s).
                if t < 0.16 {
                    let p = smooth(t / 0.16)
                    out.alpha *= CGFloat(1 - 0.6 * p); scale(1 - 0.4 * p, 1 - 0.4 * p)
                } else if t < 0.38 {
                    let p = smooth((t - 0.16) / 0.22)
                    out.alpha *= CGFloat(0.4 + 0.6 * p); scale(0.6 + 0.4 * p, 0.6 + 0.4 * p)
                }
            default: break
            }
        }
        return out
    }
}
