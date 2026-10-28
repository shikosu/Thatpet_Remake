import Foundation

/// Agents avec lesquels le personnage sait discuter.
enum Agent: String, CaseIterable, Codable {
    case claude, antigravity
    /// Copie (fork) d'une session Claude Code déjà ouverte, par exemple dans VS Code.
    case claudeSession

    var displayName: String {
        switch self { case .claude: "Claude Code"; case .antigravity: "Antigravity"; case .claudeSession: "Session Claude Code" }
    }

    /// Nom affiché devant ses réponses.
    var speaker: String {
        switch self { case .claude: "Claude"; case .antigravity: "Antigravity"; case .claudeSession: "Claude (session)" }
    }

    /// Agents qu'on peut brancher par hooks et choisir directement dans le menu.
    static let primary: [Agent] = [.claude, .antigravity]

    /// Dossier de travail du chat. Claude garde l'ancien (ses sessions y sont rattachées).
    var workDirName: String {
        switch self { case .claude: "chat-cwd"; case .antigravity: "chat-cwd-antigravity"; case .claudeSession: "chat-cwd" }
    }

    func makeRunner() -> CLIRunner {
        switch self { case .claude, .claudeSession: ClaudeRunner(); case .antigravity: AgyRunner() }
    }
}
