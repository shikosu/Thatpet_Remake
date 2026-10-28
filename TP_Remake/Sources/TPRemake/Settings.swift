import Foundation

/// Réglages de l'utilisateur, dans <données>/settings.json.
struct Settings: Codable {
    /// Le personnage se promène (marche, grimpe, saute) quand rien d'autre ne se passe.
    var wander = true
    /// Identifiant du personnage affiché (opus55 par défaut).
    var character = "opus55"
    /// Taille choisie (Tiny 0,5 · Small 0,75 · Normal 1 · Large 1,5 · Huge 2), comme dans l'original.
    var size = 1.0
    /// Particules (zzz, confettis, étincelles…).
    var particles = true
    /// Sons (alerte « Tink » quand l'agent attend une réponse).
    var sounds = true
    /// Bulle qui dit ce que fait l'agent.
    var activityBubble = true
    /// Probabilité d'une animation rare à la fin d'un tour.
    var rareChance = 0.1
    /// Dossier où l'agent travaille quand on lui écrit (nil : simple conversation) et dossiers récents.
    var workDir: String?
    var recentDirs: [String] = []
    /// Modèle choisi par agent (clé : claude / antigravity) ; absent = modèle par défaut de l'agent.
    var models: [String: String] = [:]

    private static func file(_ dd: DataDir) -> URL { dd.root.appendingPathComponent("settings.json") }

    static func load(_ dd: DataDir) -> Settings {
        guard let data = try? Data(contentsOf: file(dd)), let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    // Les réglages absents d'un ancien fichier gardent leur valeur par défaut.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wander = try c.decodeIfPresent(Bool.self, forKey: .wander) ?? true
        character = try c.decodeIfPresent(String.self, forKey: .character) ?? "opus55"
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1.0
        particles = try c.decodeIfPresent(Bool.self, forKey: .particles) ?? true
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? true
        activityBubble = try c.decodeIfPresent(Bool.self, forKey: .activityBubble) ?? true
        rareChance = try c.decodeIfPresent(Double.self, forKey: .rareChance) ?? 0.1
        workDir = try c.decodeIfPresent(String.self, forKey: .workDir)
        models = try c.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        recentDirs = try c.decodeIfPresent([String].self, forKey: .recentDirs) ?? []
    }

    /// Choisit le dossier de travail (nil : aucun) et le range en tête des récents.
    mutating func chooseWorkDir(_ path: String?) {
        workDir = path
        guard let path else { return }
        recentDirs = Array(([path] + recentDirs.filter { $0 != path }).prefix(8))
    }

    func save(_ dd: DataDir) {
        dd.prepare()
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Settings.file(dd), options: .atomic) }
    }
}
