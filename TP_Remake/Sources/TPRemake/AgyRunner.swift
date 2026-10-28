import Foundation

/// Antigravity : `agy --output-format stream-json -p=<prompt>`. Le prompt est collé au flag
/// (`-p` seul prendrait l'option suivante pour le prompt, et un message commençant par « - » serait mal lu).
final class AgyRunner: CLIRunner {
    static let briefing = """
    [Consigne] Tu es un petit personnage de bureau animé qui discute avec l'utilisateur dans une bulle. \
    Réponds dans la langue de l'utilisateur, de façon brève et directe (une à trois phrases) \
    sauf si la question demande clairement du détail.

    Message de l'utilisateur :
    """

    static let taskBriefing = """
    [Consigne] Tu es l'agent d'un petit personnage de bureau animé : l'utilisateur te confie des tâches dans le dossier \
    de travail (code, fichiers, commandes). Exécute-les avec tes outils ; chaque action sensible est validée \
    par l'utilisateur depuis le personnage, et un refus signifie qu'il ne veut pas de cette action. \
    Quand tu as fini, réponds en deux à quatre phrases : ce que tu as fait et le résultat. \
    Réponds dans la langue de l'utilisateur.

    Message de l'utilisateur :
    """

    private var lastStep: Int?

    /// Le hook PreToolUse d'Antigravity (voir `connect antigravity`) ne soumet au personnage que les runs qui portent ce drapeau.
    override var extraEnvironment: [String: String] { ["TPREMAKE_GATE": taskMode ? "1" : "web", "TPREMAKE_READ_DIRS": extraDirectories.joined(separator: ":")] }

    /// Sans le hook PreToolUse (et un délai assez long), une action passerait sans validation : on ne lance pas.
    override var preflightError: String? {
        guard taskMode, !AgentConnector.antigravityGateReady(configDir: AgentConnector.defaultAntigravityDir) else { return nil }
        return "Antigravity n'est pas prêt pour les tâches : lance « TPRemake connect antigravity » dans le terminal (mise à jour du hook d'approbation), puis réessaie."
    }

    override var missingMessage: String { "Je ne trouve pas la commande agy (Antigravity) sur ce Mac." }

    override func locate() -> URL? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["TPREMAKE_AGY"] { candidates.append(env) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/.local/bin/agy"] + Self.pathDirectories.map { "\($0)/agy" } + ["/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        return Self.firstExecutable(candidates)
    }

    override func arguments(prompt: String, sessionID: String?) -> [String] {
        var args = ["--output-format", "stream-json"]
        // Les modifications de fichiers sont acceptées par Antigravity, mais chacune passe d'abord par le hook : le personnage tranche.
        if taskMode { args += ["--mode", "accept-edits"] }
        for dir in extraDirectories { args += ["--add-dir", dir] }
        if let model { args += ["--model", model] }
        if let sessionID { args += ["--conversation", sessionID] }
        // La consigne de brièveté n'est donnée qu'au début d'une conversation.
        args.append("-p=" + (sessionID == nil ? (taskMode ? Self.taskBriefing : Self.briefing) + "\n" + prompt : prompt))
        lastStep = nil
        return args
    }

    override func handle(_ object: [String: Any]) {
        switch object["event"] as? String {
        case "init":
            if let id = object["conversation_id"] as? String { emit(.session(id)) }
        case "step_update":
            guard let step = object["step_update"] as? [String: Any],
                  step["step_type"] as? String == "agent_response",
                  let text = step["text_delta"] as? String else { return }
            let index = step["step_index"] as? Int
            if let index, let last = lastStep, index != last, !streamed.isEmpty { appendDelta("\n\n") }
            lastStep = index
            appendDelta(text)
        case "result":
            guard let result = object["result"] as? [String: Any] else { return }
            finalText = result["response"] as? String
            finalIsError = (result["status"] as? String ?? "SUCCESS") != "SUCCESS"
            if let id = result["conversation_id"] as? String { emit(.session(id)) }
        default: break
        }
    }

    /// En mode sans interface, agy refuse les outils qui demandent une permission et n'écrit alors rien :
    /// l'explication est sur stderr.
    override func resolveFinal(stderr: String, status: Int32) -> (text: String, isError: Bool) {
        if let finalText, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (finalText, finalIsError) }
        if !streamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (streamed, false) }
        return (stderr.isEmpty ? "Antigravity n'a rien répondu." : stderr, true)
    }
}
