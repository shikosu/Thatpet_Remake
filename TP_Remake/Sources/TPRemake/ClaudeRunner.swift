import Foundation

/// Claude Code : `claude -p --output-format stream-json`, le prompt arrive sur l'entrée standard.
final class ClaudeRunner: CLIRunner {
    static let systemPrompt = """
    Tu es un petit personnage de bureau animé qui discute avec l'utilisateur dans une bulle. \
    Réponds dans la langue de l'utilisateur, de façon brève et directe (une à trois phrases) \
    sauf si la question demande clairement du détail. Tu peux chercher sur internet quand c'est utile.
    """

    static let taskPrompt = """
    Tu es l'agent d'un petit personnage de bureau animé : l'utilisateur te confie des tâches dans le dossier \
    de travail (code, fichiers, commandes). Exécute-les avec tes outils ; chaque action sensible est validée \
    par l'utilisateur depuis le personnage, et un refus signifie qu'il ne veut pas de cette action. \
    Quand tu as fini, réponds en deux à quatre phrases : ce que tu as fait et le résultat. \
    Réponds dans la langue de l'utilisateur.
    """

    /// Session à copier au premier message (--resume <id> --fork-session) ; nil ensuite.
    var forkSource: String?

    override var missingMessage: String { "Je ne trouve pas Claude Code sur ce Mac." }

    /// $TPREMAKE_CLAUDE, PATH, emplacements usuels, puis l'extension VS Code.
    override func locate() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["TPREMAKE_CLAUDE"] { candidates.append(env) }
        candidates += Self.pathDirectories.map { "\($0)/claude" }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let extensions = "\(home)/.vscode/extensions"
        if let entries = try? fm.contentsOfDirectory(atPath: extensions) {
            let found = entries.filter { $0.hasPrefix("anthropic.claude-code-") && $0.contains("darwin") }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            candidates += found.reversed().map { "\(extensions)/\($0)/resources/native-binary/claude" }
        }
        return Self.firstExecutable(candidates)
    }

    override func arguments(prompt: String, sessionID: String?) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--append-system-prompt", taskMode ? Self.taskPrompt : Self.systemPrompt]
        // Hook PreToolUse réservé à ce run : le personnage valide les actions sensibles (PermissionRequest ne sert pas en -p).
        if taskMode, let binary = Bundle.main.executablePath {
            let command = "\"\(binary)\" gate --provider claude"
            let settings: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": command, "timeout": HookMode.approvalWindow + 15]]]]]]
            if let data = try? JSONSerialization.data(withJSONObject: settings), let json = String(data: data, encoding: .utf8) { args += ["--settings", json] }
        }
        // Sans dossier de travail, l'agent peut au moins chercher sur le web (lecture seule).
        if !taskMode { args += ["--allowedTools", "WebSearch,WebFetch"] }
        for dir in extraDirectories { args += ["--add-dir", dir] }
        if let model { args += ["--model", model] }
        if let forkSource { args += ["--resume", forkSource, "--fork-session"] }
        else if let sessionID { args += ["--resume", sessionID] }
        return args
    }

    override func stdinData(prompt: String) -> Data? { Data(prompt.utf8) }

    override func handle(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "system":
            if object["subtype"] as? String == "init", let id = object["session_id"] as? String { emit(.session(id)) }
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return }
            if event["type"] as? String == "content_block_start",
               (event["content_block"] as? [String: Any])?["type"] as? String == "text", !streamed.isEmpty {
                appendDelta("\n\n")
            }
            if event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                appendDelta(text)
            }
        case "assistant":
            // Appels d'outils : on montre ce que l'agent fait (outil + cible) pendant les longs travaux.
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? "outil"
                let target = HookMode.describe(tool: name, input: block["input"] as? [String: Any] ?? [:])
                    .split(separator: "\n").first.map(String.init) ?? ""
                emit(.step(target.isEmpty ? name : "\(name) : \(String(target.prefix(80)))"))
            }
        case "result":
            finalText = object["result"] as? String
            finalIsError = object["is_error"] as? Bool ?? false
            if let id = object["session_id"] as? String { emit(.session(id)) }
        default: break
        }
    }
}
