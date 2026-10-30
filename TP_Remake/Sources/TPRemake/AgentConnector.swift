import Foundation

/// Installe / retire nos hooks dans la config des agents sans toucher aux hooks des autres outils.
///  - Claude Code : ~/.claude/settings.json (clé "hooks")
///  - Antigravity : ~/.gemini/config/hooks.json (entrée nommée "tpremake")
enum AgentConnector {
    struct ConnectError: Error, CustomStringConvertible { let description: String }

    /// Marqueur qui identifie nos commandes (ThatPet et les autres outils ne l'ont pas).
    private static let marker = "--tpremake"
    private static let antigravityKey = "tpremake"
    static let antigravityEvents = ["SessionStart", "PreInvocation", "PreToolUse", "PostToolUse", "Stop"]

    static func command(binary: String, provider: String, event: String) -> String {
        "\"\(binary)\" hook --provider \(provider) --event \(event) \(marker)"
    }

    /// Chemin du binaire d'une commande de hook (entre guillemets en tête).
    static func binaryPath(in command: String) -> String? {
        guard command.hasPrefix("\""), let end = command.dropFirst().firstIndex(of: "\"") else { return nil }
        return String(command[command.index(after: command.startIndex)..<end])
    }

    static func isOurs(_ command: String) -> Bool { command.contains(marker) }

    static var defaultConfigDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var defaultAntigravityDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config")
    }

    // MARK: - Claude Code

    static func connect(configDir: URL, binary: String) throws -> String {
        let file = "settings.json"
        var settings = try read(configDir, file)
        let backup = try makeBackup(configDir, file)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        _ = strip(&hooks)
        for event in AgentEvents.hookEvents {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            groups.append(["hooks": [["type": "command", "command": command(binary: binary, provider: "claude", event: event),
                                      "timeout": event == "PermissionRequest" ? HookMode.approvalWindow + 15 : 5]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try write(settings, configDir, file)
        return "\(configDir.path): \(AgentEvents.hookEvents.count) hooks installés" + (backup.map { ", sauvegarde \($0)" } ?? "")
    }

    static func disconnect(configDir: URL) throws -> String {
        let file = "settings.json"
        var settings = try read(configDir, file)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        let removed = strip(&hooks)
        guard removed > 0 else { return "\(configDir.path): aucun hook TPRemake" }
        let backup = try makeBackup(configDir, file)
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try write(settings, configDir, file)
        return "\(configDir.path): \(removed) hooks retirés" + (backup.map { ", sauvegarde \($0)" } ?? "")
    }

    static func isConnected(configDir: URL) -> Bool {
        guard let settings = try? read(configDir, "settings.json"), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [[String: Any]])?.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains { isOurs($0["command"] as? String ?? "") } ?? false
        } ?? false }
    }

    /// Retire nos entrées ; les groupes ou événements devenus vides disparaissent. Renvoie le nombre retiré.
    private static func strip(_ hooks: inout [String: Any]) -> Int {
        var removed = 0
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var group in groups {
                let handlers = (group["hooks"] as? [[String: Any]]) ?? []
                let mine = handlers.filter { isOurs($0["command"] as? String ?? "") }
                removed += mine.count
                if mine.isEmpty { kept.append(group); continue }
                let others = handlers.filter { !isOurs($0["command"] as? String ?? "") }
                if !others.isEmpty { group["hooks"] = others; kept.append(group) }
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        return removed
    }

    // MARK: - Antigravity

    /// Format observé dans hooks.json : événements sans outil = gestionnaires à plat,
    /// événements d'outil = groupes { matcher, hooks: [...] }.
    static func antigravityEntry(binary: String) -> [String: Any] {
        func handler(_ event: String) -> [String: Any] {
            ["type": "command", "command": command(binary: binary, provider: "antigravity", event: event), "timeout": event == "PreToolUse" ? HookMode.approvalWindow + 15 : 5]
        }
        var entry: [String: Any] = ["enabled": true]
        for event in antigravityEvents {
            entry[event] = ["PreToolUse", "PostToolUse"].contains(event)
                ? [["matcher": "", "hooks": [handler(event)]]]
                : [handler(event)]
        }
        return entry
    }

    static func connectAntigravity(configDir: URL, binary: String) throws -> String {
        let file = "hooks.json"
        var root = try read(configDir, file)
        let backup = try makeBackup(configDir, file)
        root[antigravityKey] = antigravityEntry(binary: binary)
        try write(root, configDir, file)
        return "\(configDir.path): hooks Antigravity installés" + (backup.map { ", sauvegarde \($0)" } ?? "")
            + " (relancez Antigravity pour les charger)"
    }

    static func disconnectAntigravity(configDir: URL) throws -> String {
        let file = "hooks.json"
        var root = try read(configDir, file)
        guard root[antigravityKey] != nil else { return "\(configDir.path): aucun hook TPRemake" }
        let backup = try makeBackup(configDir, file)
        root.removeValue(forKey: antigravityKey)
        try write(root, configDir, file)
        return "\(configDir.path): hooks Antigravity retirés" + (backup.map { ", sauvegarde \($0)" } ?? "")
    }

    static func isAntigravityConnected(configDir: URL) -> Bool {
        guard let root = try? read(configDir, "hooks.json"), let entry = root[antigravityKey] as? [String: Any] else { return false }
        return entry["enabled"] as? Bool ?? true
    }

    /// Le hook PreToolUse est installé avec un délai qui laisse le temps de répondre depuis le personnage.
    /// Trop court, Antigravity laisserait passer l'action sans attendre (constaté : le hook qui dépasse son délai est ignoré).
    static func antigravityGateReady(configDir: URL) -> Bool {
        guard isAntigravityConnected(configDir: configDir),
              let root = try? read(configDir, "hooks.json"), let entry = root[antigravityKey] as? [String: Any],
              let groups = entry["PreToolUse"] as? [[String: Any]],
              let handlers = groups.first?["hooks"] as? [[String: Any]],
              let timeout = handlers.first?["timeout"] as? Double ?? (handlers.first?["timeout"] as? Int).map(Double.init)
        else { return false }
        // Si le binaire du hook a disparu, Antigravity laisserait tout passer : la porte n'est pas fermée.
        let commands = groups.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
        guard let command = commands.first, let binary = binaryPath(in: command),
              FileManager.default.isExecutableFile(atPath: binary) else { return false }
        return timeout >= Double(HookMode.approvalWindow + 5)
    }

    // MARK: - Fichiers

    private static func read(_ dir: URL, _ name: String) throws -> [String: Any] {
        let file = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectError(description: "\(file.path) n'est pas un objet JSON valide ; je n'y touche pas")
        }
        if name == "settings.json", let hooks = object["hooks"], !(hooks is [String: Any]) {
            throw ConnectError(description: "\(file.path) : « hooks » n'est pas un objet ; je n'y touche pas")
        }
        return object
    }

    private static func makeBackup(_ dir: URL, _ name: String) throws -> String? {
        let file = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backup = dir.appendingPathComponent("\(name).tpremake-backup-\(stamp.string(from: Date()))")
        try FileManager.default.copyItem(at: file, to: backup)
        return backup.lastPathComponent
    }

    private static func write(_ object: [String: Any], _ dir: URL, _ name: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}
