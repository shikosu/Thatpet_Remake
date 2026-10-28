import Foundation

/// `TPRemake hook --provider claude` : appelé par l'agent à chaque événement.
/// Ne bloque jamais l'agent : sauf décision explicite du personnage, aucune sortie et code 0.
enum HookMode {
    /// Secondes pendant lesquelles un hook PermissionRequest attend la réponse du personnage.
    static var approvalWindow: Int {
        Int(ProcessInfo.processInfo.environment["TPREMAKE_APPROVAL_TIMEOUT"] ?? "") ?? 90
    }

    static func run(arguments: [String], dataDir: DataDir) -> Int32 {
        let provider = value(of: "--provider", in: arguments) ?? "claude"
        var payload: [String: Any] = [:]
        if isatty(STDIN_FILENO) == 0,
           let object = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any] {
            payload = object
        }
        let event = (payload["hook_event_name"] as? String) ?? value(of: "--event", in: arguments) ?? ""
        guard let state = AgentEvents.state(for: event) else { return 0 }

        var message = AgentMessage(
            provider: provider, event: event, state: state,
            session: sanitize(firstString(payload, ["session_id", "conversation_id", "conversationId"]) ?? "default"),
            tool: toolCall(in: payload).name.nilIfEmpty.map { sanitize($0) })
        message.cwd = (payload["cwd"] as? String).map { String($0.prefix(300)) }

        if event == "PermissionRequest" {
            return askPet(&message, payload: payload, dataDir: dataDir)
        }
        // Chat du personnage avec Antigravity : les actions sensibles passent par lui.
        if provider == "antigravity", event == "PreToolUse", let mode = ProcessInfo.processInfo.environment["TPREMAKE_GATE"] {
            // Recherche web : lecture seule, autorisée explicitement (sans décision, Antigravity la refuse en mode sans interface).
            let call = toolCall(in: payload)
            // Lecture d'un fichier joint : Antigravity refuse sinon, sans interface, tout ce qui sort du dossier de travail.
            if !needsApproval(tool: call.name, input: call.input), readsOnlyAttachments(call.input) {
                writeState(message, dataDir: dataDir)
                print("{\"decision\":\"allow\"}")
                return 0
            }
            if webTools.contains(call.name) {
                writeState(message, dataDir: dataDir)
                print("{\"decision\":\"allow\"}")
                return 0
            }
            if mode == "1" { return gate(provider: provider, payload: payload, dataDir: dataDir) }
        }
        writeState(message, dataDir: dataDir)
        if let data = try? JSONEncoder().encode(message) { _ = PetSocket.send(data, to: dataDir.socket) }
        // Antigravity lit un JSON sur la sortie du hook : « {} » = aucune décision.
        if provider == "antigravity" { print("{}") }
        return 0
    }

    private static func firstString(_ payload: [String: Any], _ keys: [String]) -> String? {
        keys.lazy.compactMap { payload[$0] as? String }.first
    }

    // MARK: - Approbation

    /// Envoie la demande au personnage et attend sa décision ; sans réponse, Claude demande lui-même.
    private static func askPet(_ message: inout AgentMessage, payload: [String: Any], dataDir: DataDir) -> Int32 {
        let detail = describe(tool: payload["tool_name"] as? String ?? "", input: payload["tool_input"] as? [String: Any] ?? [:])
        guard let answer = requestDecision(&message, detail: detail, dataDir: dataDir) else { return 0 }
        var decision: [String: Any]
        switch answer.behavior {
        case "allow": decision = ["behavior": "allow"]
        case "deny": decision = ["behavior": "deny", "message": answer.message ?? "Refusé par l'utilisateur depuis le personnage.", "interrupt": false]
        default: return 0   // « ask » : on laisse Claude demander
        }
        printJSON(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
        return 0
    }

    /// Affiche la demande au-dessus du personnage et attend « allow », « deny » ou « ask ».
    /// nil : personnage fermé, délai écoulé ou réponse illisible.
    private static func requestDecision(_ message: inout AgentMessage, detail: String, dataDir: DataDir) -> (behavior: String, message: String?)? {
        dataDir.prepare()
        let timeout = approvalWindow
        guard let reply = ReplySocket(url: dataDir.run.appendingPathComponent("r\(getpid()).sock")) else { return nil }
        message.event = "PermissionRequest"
        message.state = "attention"
        message.reply = reply.url.path
        message.expires = Date().timeIntervalSince1970 + Double(timeout)
        message.detail = detail

        writeState(message, dataDir: dataDir)
        // Un datagramme UNIX est limité à ~2 Ko : on raccourcit le détail si besoin.
        var data = (try? JSONEncoder().encode(message)) ?? Data()
        while data.count > 1800, let detail = message.detail, detail.count > 40 {
            message.detail = String(detail.prefix(detail.count / 2)) + "…"
            data = (try? JSONEncoder().encode(message)) ?? Data()
        }
        guard PetSocket.send(data, to: dataDir.socket) else { return nil }   // app fermée : comportement normal

        guard let answer = reply.wait(timeout: Double(timeout)),
              let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let behavior = object["behavior"] as? String else { return nil }
        return (behavior, object["message"] as? String)
    }

    private static func printJSON(_ object: [String: Any]) {
        if let json = try? JSONSerialization.data(withJSONObject: object), let text = String(data: json, encoding: .utf8) { print(text) }
    }

    // MARK: - Porte d'entrée des actions (chats lancés par le personnage)

    /// `TPRemake gate --provider claude` (ajouté par le personnage aux runs de Claude Code) ou le hook PreToolUse
    /// d'Antigravity quand TPREMAKE_GATE=1 : les lectures passent, le reste est soumis au personnage.
    /// En mode `-p`, le hook PermissionRequest de Claude n'est jamais appelé (constaté) : PreToolUse décide à sa place.
    static func gate(provider: String, payload: [String: Any], dataDir: DataDir) -> Int32 {
        let call = toolCall(in: payload)
        let silent = { () -> Int32 in if provider == "antigravity" { print("{}") }; return 0 }
        guard !call.name.isEmpty, needsApproval(tool: call.name, input: call.input) else {
            dataDir.appendLog("gate[\(provider)]: \(call.name) laissé passer")
            return silent()
        }
        // Antigravity sans interface ne peut pas lancer de commande, même autorisée par un hook : inutile de déranger l'utilisateur.
        if provider == "antigravity", (call.input["CommandLine"] ?? call.input["command"]) != nil {
            dataDir.appendLog("gate[\(provider)]: \(call.name) (commande) laissé à Antigravity")
            return silent()
        }
        let detail = describe(tool: call.name, input: call.input)
        var message = AgentMessage(
            provider: provider, event: "PermissionRequest", state: "attention",
            session: sanitize(firstString(payload, ["session_id", "conversation_id", "conversationId"]) ?? "default"),
            tool: sanitize(call.name))
        message.cwd = (payload["cwd"] as? String).map { String($0.prefix(300)) }

        var answer: (behavior: String, message: String?)?
        if let auto = ProcessInfo.processInfo.environment["TPREMAKE_GATE_AUTO"] {   // tests sans personnage
            answer = (auto, nil)
        } else {
            answer = requestDecision(&message, detail: detail, dataDir: dataDir)
        }
        dataDir.appendLog("gate[\(provider)]: \(call.name) \(call.input.keys.sorted()) → \(answer?.behavior ?? "sans réponse")")
        guard let answer, answer.behavior == "allow" || answer.behavior == "deny" else {
            // Antigravity laisse passer une action si le hook ne tranche pas : sans réponse, on refuse.
            if provider == "antigravity" { printJSON(["decision": "deny", "reason": "Pas de réponse du personnage : action refusée."]) } else { _ = silent() }
            return 0
        }
        let reason = answer.behavior == "deny" ? (answer.message ?? "Refusé par l'utilisateur depuis le personnage.") : "Autorisé depuis le personnage."
        if provider == "antigravity" {
            var output: [String: Any] = ["decision": answer.behavior, "reason": reason]
            // Sans interface, "allow" ne suffit pas : l'action doit aussi être couverte par une permission temporaire.
            if answer.behavior == "allow" { output["permissionOverrides"] = [permissionRule(tool: call.name, input: call.input)] }
            printJSON(output)
        } else {
            printJSON(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": answer.behavior,
                                              "permissionDecisionReason": reason]])
        }
        return 0
    }

    /// Règle de permission Antigravity pour cet appel : « command(npm test) », « write_file(/chemin) »…
    static func permissionRule(tool: String, input: [String: Any]) -> String {
        if let command = (input["command"] ?? input["CommandLine"]) as? String { return "command(\(command))" }
        let target = (input["Path"] ?? input["TargetFile"] ?? input["AbsolutePath"] ?? input["path"] ?? input["Url"]) as? String
        return target.map { "\(tool)(\($0))" } ?? tool
    }

    /// Nom et paramètres de l'outil appelé (Claude : tool_name/tool_input ; Antigravity : toolCall.name/args).
    static func toolCall(in payload: [String: Any]) -> (name: String, input: [String: Any]) {
        if let name = payload["tool_name"] as? String { return (name, payload["tool_input"] as? [String: Any] ?? [:]) }
        if let call = payload["toolCall"] as? [String: Any], let name = call["name"] as? String {
            return (name, call["args"] as? [String: Any] ?? [:])
        }
        return ((payload["toolName"] as? String) ?? "", [:])
    }

    /// Vrai si le chemin visé est dans un dossier de fichiers joints (TPREMAKE_READ_DIRS).
    private static func readsOnlyAttachments(_ input: [String: Any]) -> Bool {
        let dirs = (ProcessInfo.processInfo.environment["TPREMAKE_READ_DIRS"] ?? "").split(separator: ":").map(String.init)
        let paths = input.values.compactMap { $0 as? String }.filter { $0.hasPrefix("/") }
        guard !dirs.isEmpty, !paths.isEmpty else { return false }
        return paths.allSatisfy { path in
            let clean = URL(fileURLWithPath: path).standardizedFileURL.path
            return dirs.contains { clean == $0 || clean.hasPrefix($0 + "/") }
        }
    }

    private static let webTools: Set<String> = ["search_web", "read_url_content"]
    private static let readOnlyTools: Set<String> = [
        "Read", "Glob", "Grep", "LS", "TodoWrite", "ExitPlanMode", "WebSearch", "Skill", "ToolSearch", "BashOutput",
        "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "AskUserQuestion",
    ]
    private static let readOnlyWords = ["view", "list", "read", "grep", "find", "search", "glob", "ls", "todo", "question", "outline"]
    private static let readOnlyCommands: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "echo", "which", "grep", "rg", "tree", "date", "whoami", "file", "stat", "du", "df", "uname", "basename", "dirname",
    ]
    private static let readOnlyGit: Set<String> = ["status", "diff", "log", "show", "branch", "remote", "rev-parse", "ls-files", "blame"]

    /// Faux pour les lectures sans effet de bord ; vrai pour tout le reste (écriture, commande, réseau, outil inconnu).
    static func needsApproval(tool: String, input: [String: Any]) -> Bool {
        if readOnlyTools.contains(tool) { return false }
        let command = (input["command"] ?? input["CommandLine"]) as? String
        if let command { return !isHarmless(command) }
        // Antigravity : outils nommés en minuscules_avec_tirets bas (view_file, list_dir, grep_search…) ; on juge le premier mot.
        if tool == tool.lowercased(), let first = tool.split(separator: "_").first, readOnlyWords.contains(String(first)) { return false }
        return true
    }

    /// Commande simple et sans effet : un seul programme connu, sans redirection, enchaînement ni substitution.
    static func isHarmless(_ command: String) -> Bool {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>$`\\\n()")) == nil else { return false }
        let parts = text.split(separator: " ").map(String.init)
        guard let program = parts.first else { return false }
        if program == "git" { return parts.count > 1 && readOnlyGit.contains(parts[1]) }
        if program == "find" { return !parts.contains { ["-exec", "-delete", "-ok", "-execdir"].contains($0) } }
        return readOnlyCommands.contains(program)
    }

    /// Résumé lisible de l'action demandée (commande, fichier, URL…).
    static func describe(tool: String, input: [String: Any]) -> String {
        func str(_ key: String) -> String? { input[key] as? String }
        let text: String
        if let command = str("command") ?? str("CommandLine") { text = command }
        else if let path = str("file_path") ?? str("notebook_path") ?? str("path") ?? str("Path") ?? str("TargetFile") ?? str("AbsolutePath") { text = path }
        else if let url = str("url") ?? str("Url") { text = url }
        else if let pattern = str("pattern") { text = pattern }
        else if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
                let json = String(data: data, encoding: .utf8) { text = json }
        else { text = "" }
        return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    // MARK: - Utilitaires

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func sanitize(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:")).contains($0) }.prefix(128))
    }

    /// run/state : « <état> <ms> agent=… session=… » (écriture atomique).
    private static func writeState(_ m: AgentMessage, dataDir: DataDir) {
        dataDir.prepare()
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let line = "\(m.state) \(ms) agent=\(m.provider) session=\(m.session)" + (m.tool.map { " tool=\($0)" } ?? "") + "\n"
        try? line.write(to: dataDir.state, atomically: true, encoding: .utf8)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
