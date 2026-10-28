import Foundation

/// Un personnage trouvé sur le disque (pack.json lu, images non chargées).
struct CharacterInfo {
    let id: String
    let name: String
    let directory: URL
    /// D'où vient le pack : « inclus », « TPRemake » ou « ThatPet ».
    let source: String
}

/// Cherche les packs de personnages. Les packs de ThatPet sont lus sur place (jamais copiés).
enum PackLibrary {
    static func roots(bundled: URL, dataDir: DataDir) -> [(url: URL, source: String)] {
        var roots: [(URL, String)] = [(bundled, "inclus"), (dataDir.root.appendingPathComponent("characters"), "TPRemake")]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        roots.append((support.appendingPathComponent("ThatPet/characters"), "ThatPet"))
        if let extra = ProcessInfo.processInfo.environment["TPREMAKE_PACKS"] {
            for path in extra.split(separator: ":") { roots.append((URL(fileURLWithPath: String(path)), "dossier perso")) }
        }
        return roots
    }

    /// Tous les personnages valides ; en cas de doublon d'identifiant, le premier dossier de la liste gagne.
    static func discover(bundled: URL, dataDir: DataDir) -> [CharacterInfo] {
        var found: [CharacterInfo] = []
        var seen = Set<String>()
        for (root, source) in roots(bundled: bundled, dataDir: dataDir) {
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("pack.json")),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["format"] as? String == "thatpet-pack/1",
                      let id = json["id"] as? String, !seen.contains(id) else { continue }
                seen.insert(id)
                found.append(CharacterInfo(id: id, name: json["name"] as? String ?? id, directory: dir, source: source))
            }
        }
        return found
    }

    static func find(_ id: String, bundled: URL, dataDir: DataDir) -> CharacterInfo? {
        discover(bundled: bundled, dataDir: dataDir).first { $0.id == id }
    }
}
