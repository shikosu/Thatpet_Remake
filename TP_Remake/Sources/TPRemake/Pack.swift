import AppKit

/// Un personnage au format `thatpet-pack/1` (pack.json + poses/*.png).
struct Pack {
    struct Animation {
        let frames: [(pose: String, ms: Int)]
        let loop: Bool
        let repeatCount: Int
        let next: String?
        let fx: [String]
        /// Durée du fondu enchaîné au début de chaque image (ms ; 0 = aucun).
        let xfade: Int
        /// Effets de particules (zzz, confetti…).
        let particles: [String]
        /// Grimper sur le mur de droite = image miroir (l'art est dessiné pour le mur de gauche).
        let mirrorOnRightWall: Bool
    }

    let id: String
    let name: String
    let canvas: CGFloat
    let floor: CGFloat
    /// Hauteur du personnage debout, en fraction du cadre (0,76 si le pack ne la précise pas, comme l'original).
    let standHeight: CGFloat
    let poses: [String: CGImage]
    /// Point d'ancrage de chaque pose : feet, top, center ou wall.
    let anchors: [String: String]
    /// Zone opaque de chaque pose, en fractions du cadre (origine en haut à gauche).
    let bounds: [String: CGRect]
    /// Abscisse (fraction du cadre) du haut du personnage : le point par lequel on le tient quand on le saisit.
    let topCenters: [String: CGFloat]
    let animations: [String: Animation]

    /// Plus grande hauteur / largeur d'une pose (fractions du cadre) : sert à ne jamais dépasser l'écran.
    var tallestPose: CGFloat { bounds.values.map { $0.height }.max() ?? 1 }
    var widestPose: CGFloat { bounds.values.map { $0.width }.max() ?? 1 }

    enum LoadError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { if case .invalid(let m) = self { return m }; return "" }
    }

    static func load(from dir: URL) throws -> Pack {
        let data = try Data(contentsOf: dir.appendingPathComponent("pack.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == "thatpet-pack/1",
              let id = root["id"] as? String,
              let poseDefs = root["poses"] as? [String: [String: Any]],
              let animDefs = root["animations"] as? [String: [String: Any]]
        else { throw LoadError.invalid("pack.json invalide dans \(dir.path)") }

        var poses: [String: CGImage] = [:]
        var anchors: [String: String] = [:]
        var bounds: [String: CGRect] = [:]
        var topCenters: [String: CGFloat] = [:]
        for (name, def) in poseDefs {
            guard let file = def["file"] as? String,
                  let image = NSImage(contentsOf: dir.appendingPathComponent(file)),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { throw LoadError.invalid("pose illisible : \(name)") }
            poses[name] = cg
            anchors[name] = def["anchor"] as? String ?? "feet"
            let measured = opaqueBounds(of: cg)
            bounds[name] = measured.rect
            topCenters[name] = measured.topCenterX
        }

        var animations: [String: Animation] = [:]
        for (name, def) in animDefs {
            let frames = (def["frames"] as? [[Any]] ?? []).compactMap { f -> (String, Int)? in
                guard f.count == 2, let p = f[0] as? String, let ms = f[1] as? Int, poses[p] != nil else { return nil }
                return (p, ms)
            }
            guard !frames.isEmpty else { continue }
            animations[name] = Animation(
                frames: frames,
                loop: def["loop"] as? Bool ?? true,
                repeatCount: def["repeat"] as? Int ?? 1,
                next: def["next"] as? String,
                fx: def["fx"] as? [String] ?? [],
                xfade: def["xfade"] as? Int ?? 0,
                particles: def["particles"] as? [String] ?? [],
                mirrorOnRightWall: def["mirror_on_right_wall"] as? Bool ?? false)
        }
        var standHeight: CGFloat = 0.76
        if let value = root["stand_height"] as? Double {
            guard value > 0.1, value <= 1 else { throw LoadError.invalid("stand_height \(value) doit être dans ]0,1 ; 1]") }
            standHeight = CGFloat(value)
        }
        guard animations["idle"] != nil else { throw LoadError.invalid("animation « idle » obligatoire") }

        return Pack(id: id, name: root["name"] as? String ?? id,
                    canvas: CGFloat(root["canvas"] as? Double ?? 512),
                    floor: CGFloat(root["floor"] as? Double ?? 0.965),
                    standHeight: standHeight,
                    poses: poses, anchors: anchors, bounds: bounds, topCenters: topCenters, animations: animations)
    }

    /// Rectangle des pixels non transparents (alpha > 20), normalisé, origine en haut à gauche.
    static func opaqueBounds(of image: CGImage) -> (rect: CGRect, topCenterX: CGFloat) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let full = (rect: CGRect(x: 0, y: 0, width: 1, height: 1), topCenterX: CGFloat(0.5))
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return full }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {                       // la ligne 0 du tampon est le haut de l'image
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 20 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return full }
        let rect = CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
                          width: CGFloat(maxX + 1 - minX) / CGFloat(w), height: CGFloat(maxY + 1 - minY) / CGFloat(h))
        // Milieu des pixels opaques du haut (les 6 % supérieurs de la silhouette).
        var sum = 0, count = 0
        for y in minY..<min(maxY + 1, minY + max(1, (maxY + 1 - minY) * 6 / 100)) {
            for x in minX...maxX where data[(y * w + x) * 4 + 3] > 20 { sum += x; count += 1 }
        }
        return (rect, count > 0 ? (CGFloat(sum) / CGFloat(count) + 0.5) / CGFloat(w) : rect.midX)
    }
}
