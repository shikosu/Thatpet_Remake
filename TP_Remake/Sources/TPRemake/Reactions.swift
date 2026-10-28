import Foundation

/// Choisit l'animation à jouer selon l'état de l'agent. Sait faire monter l'attention (30 s), remercier après une
/// attention résolue, tirer une « surprise rare » à la fin d'un tour (avec délai de repos) et demander un rappel sonore.
final class ReactionEngine {
    enum Change: Equatable {
        case keep                    // rien à changer
        case play(String?)           // nouvelle animation d'agent (nil : retour à la vie normale)
    }
    struct Result: Equatable {
        var change: Change
        var sounds: [String] = []
    }

    /// Probabilité qu'une fin de tour déclenche l'animation rare (réglage « rare_chance » de l'original).
    var rareChance = 0.1
    /// Délai minimal entre deux animations rares.
    var rareCooldown = 3600.0
    /// Au bout de ce délai sans réponse, l'attention devient « urgente ».
    var escalateAfter = 30.0
    /// Rappel sonore tant que l'attention reste sans réponse.
    var reminderEvery = 45.0

    private var rng: SplitMix64
    private var previous = "idle"
    private var attentionSince: Double?
    private var lastReminder = 0.0
    private var urgent = false
    private var lastRare = -Double.infinity

    init(seed: UInt64) { rng = SplitMix64(state: seed) }

    /// État d'agent reçu (idle, thinking, working, attention, helper, toolfail, celebrating, compacting, error, stop).
    func react(to state: String, now: Double, has: (String) -> Bool) -> Result {
        defer { previous = state }
        if state == "attention" {
            attentionSince = now
            lastReminder = now
            urgent = false
            return Result(change: .play(has("attention") ? "attention" : nil), sounds: ["Tink"])
        }
        attentionSince = nil
        urgent = false

        func pick(_ name: String) -> Change { .play(has(name) ? name : "idle") }
        switch state {
        case "idle", "stop": return Result(change: .play(nil))
        case "thinking": return Result(change: pick("thinking"))
        case "working":
            // Tout de suite après une attention résolue : un petit merci (puis « working » par l'enchaînement du pack).
            return Result(change: previous == "attention" && has("grateful") ? .play("grateful") : pick("working"))
        case "helper": return Result(change: pick("helper"))
        case "toolfail": return Result(change: pick("oops"))
        case "compacting": return Result(change: pick("compacting"))
        case "error": return Result(change: pick("error"))
        case "celebrating":
            if has("rare_surprise"), now - lastRare >= rareCooldown, Double.random(in: 0..<1, using: &rng) < rareChance {
                lastRare = now
                return Result(change: .play("rare_surprise"))
            }
            return Result(change: pick("celebrating"))
        default: return Result(change: .keep)
        }
    }

    /// À appeler régulièrement : fait monter l'attention et émet les rappels.
    func tick(now: Double, has: (String) -> Bool) -> Result {
        guard let since = attentionSince else { return Result(change: .keep) }
        if !urgent, now - since >= escalateAfter, has("attention_urgent") {
            urgent = true
            lastReminder = now
            return Result(change: .play("attention_urgent"), sounds: ["Tink"])
        }
        if now - lastReminder >= reminderEvery {
            lastReminder = now
            return Result(change: .keep, sounds: ["Tink"])
        }
        return Result(change: .keep)
    }
}

extension AgentEvents {
    /// Texte de la bulle d'activité (« ce que fait l'agent ») pour un état et, le cas échéant, un outil.
    static func bubbleText(state: String, tool: String?) -> String? {
        switch state {
        case "thinking": return "Réfléchit…"
        case "working":
            guard let tool, !tool.isEmpty else { return "Travaille sur l'ordinateur" }
            return toolText(tool)
        case "attention": return "A besoin de vous !"
        case "helper": return "Appelle un assistant"
        case "toolfail": return "Oups, un outil a échoué"
        case "compacting": return "Fait de la place…"
        case "error": return "Une erreur est survenue"
        case "celebrating": return "Terminé !"
        default: return nil
        }
    }

    /// Libellé selon le nom de l'outil (motifs relevés dans l'original : édition, commande, lecture, recherche, web…).
    static func toolText(_ tool: String) -> String {
        let t = tool.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if t.hasPrefix("mcp__") {
            let parts = t.split(separator: "_", omittingEmptySubsequences: true)
            let server = parts.count > 1 ? String(parts[1]) : "un outil"
            return "Utilise \(server)"
        }
        // Du plus spécifique au plus général : « WebSearch » contient « search », « TodoWrite » contient « write ».
        if has(["todo", "plan"]) { return "Planifie" }
        if has(["webfetch", "websearch", "web_search", "web_fetch", "read_url", "browser", "fetch"]) { return "Navigue sur le web" }
        if has(["task", "agent", "delegate", "subagent"]) { return "Demande à un assistant" }
        if has(["image"]) { return "Crée une image" }
        if has(["edit", "multiedit", "write", "patch", "apply_patch", "notebook", "replace_file", "sed_file"]) { return "Modifie un fichier" }
        if has(["bash", "shell", "run_command", "run_terminal", "exec_command", "terminal", "command"]) { return "Lance une commande" }
        if has(["read", "view"]) { return "Lit un fichier" }
        if has(["grep", "glob", "search", "find", "list_dir"]) { return "Cherche dans le projet" }
        return "Utilise un outil"
    }
}
