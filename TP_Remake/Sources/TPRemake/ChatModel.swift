import Foundation

struct ChatMessage: Codable {
    enum Role: String, Codable { case user, assistant }
    var role: Role
    var text: String
    var isError = false
}

extension Notification.Name {
    static let chatChanged = Notification.Name("TPRemakeChatChanged")
}

/// Conversations avec les agents (une par agent, reprise par identifiant de session), persistées dans chat.json.
final class ChatModel {
    private struct AgentChat: Codable {
        var sessionID: String?
        var messages: [ChatMessage] = []
        /// Session « en cours » copiée : identifiant d'origine, dossier de travail, nom affiché.
        var source: String?
        var cwd: String?
        var label: String?
    }
    private struct Stored: Codable { var current: Agent; var chats: [String: AgentChat] }
    /// Ancien format (avant le choix d'agent) : une seule conversation, celle de Claude.
    private struct Legacy: Codable { var sessionID: String?; var messages: [ChatMessage] }

    private let dataDir: DataDir
    private var runners: [Agent: CLIRunner] = [:]
    private var chats: [String: AgentChat] = [:]
    private(set) var agent: Agent
    /// Dossier de travail des agents (mode tâches). nil : simple conversation, sans outils.
    private(set) var workDir: URL?
    /// Modèle choisi par agent (clé : Agent.rawValue ; la copie de session suit Claude).
    var models: [String: String] = [:]

    /// Une conversation par agent, et par dossier en mode tâches (une session Claude est rattachée à son dossier).
    private func key(_ agent: Agent) -> String {
        guard let workDir, agent != .claudeSession else { return agent.rawValue }
        return "\(agent.rawValue)@\(workDir.path)"
    }

    var messages: [ChatMessage] { chats[key(agent)]?.messages ?? [] }
    var sessionID: String? { chats[key(agent)]?.sessionID }
    /// Session d'origine de la conversation « session en cours » (nil si aucune).
    var liveSource: String? { chats[Agent.claudeSession.rawValue]?.source }
    var isBusy: Bool { runners.values.contains { $0.isRunning } }

    /// Texte courant de la réponse (flux) et fin de réponse.
    var onReply: ((_ text: String, _ isFinal: Bool, _ isError: Bool) -> Void)?

    var attachmentsDirectory: URL { dataDir.root.appendingPathComponent("attachments") }

    private var file: URL { dataDir.root.appendingPathComponent("chat.json") }

    init(dataDir: DataDir, agent: Agent? = nil) {
        self.dataDir = dataDir
        self.agent = .claude
        if let data = try? Data(contentsOf: file) {
            if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
                chats = stored.chats
                self.agent = stored.current
            } else if let legacy = try? JSONDecoder().decode(Legacy.self, from: data) {
                chats[Agent.claude.rawValue] = AgentChat(sessionID: legacy.sessionID, messages: legacy.messages)
            }
        }
        if let agent { self.agent = agent }
    }

    /// Change d'agent (refusé pendant qu'un agent répond).
    @discardableResult
    func select(_ newAgent: Agent) -> Bool {
        guard !isBusy else { return false }
        if newAgent == .claudeSession, chats[newAgent.rawValue]?.source == nil { return false }   // aucune session choisie
        agent = newAgent
        save()
        changed()
        return true
    }

    /// Change de dossier de travail (refusé pendant qu'un agent répond).
    @discardableResult
    func setWorkDir(_ url: URL?) -> Bool {
        guard !isBusy else { return false }
        workDir = url
        changed()
        return true
    }

    /// Titre de la conversation courante.
    var title: String {
        if agent == .claudeSession, let label = chats[agent.rawValue]?.label { return "\(agent.displayName) — \(label)" }
        if let workDir { return "\(agent.displayName) — \(workDir.lastPathComponent)" }
        return agent.displayName
    }

    /// Choisit la session Claude Code à copier. Une autre session que la précédente repart d'une page blanche.
    @discardableResult
    func attachLive(sessionID: String, cwd: String, label: String) -> Bool {
        guard !isBusy else { return false }
        let key = Agent.claudeSession.rawValue
        if chats[key]?.source != sessionID {
            chats[key] = AgentChat(sessionID: nil, messages: [], source: sessionID, cwd: cwd, label: label)
        }
        agent = .claudeSession
        save()
        changed()
        return true
    }

    /// Une session créée par nos propres chats (à ne pas proposer comme « session en cours »).
    func isOwnSession(_ id: String) -> Bool { chats.values.contains { $0.sessionID == id } }

    /// Fichiers joints au prochain message (partagés par la bulle et la fenêtre de chat).
    private(set) var attachments: [URL] = []

    func attach(_ urls: [URL]) {
        for url in urls where !attachments.contains(url) { attachments.append(url) }
        changed()
    }

    func clearAttachments() {
        attachments = []
        changed()
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isBusy else { return }
        let files = attachments
        attachments = []
        var prompt = trimmed.isEmpty ? "Regarde les fichiers joints." : trimmed
        var shown = trimmed
        if !files.isEmpty {
            prompt += "\n\nFichiers joints (lis-les avec tes outils) :\n" + files.map { "- " + $0.path }.joined(separator: "\n")
            shown += (shown.isEmpty ? "" : "\n") + "📎 " + files.map(\.lastPathComponent).joined(separator: ", ")
        }
        let agent = self.agent
        update(agent) {
            $0.messages.append(ChatMessage(role: .user, text: shown))
            $0.messages.append(ChatMessage(role: .assistant, text: ""))
        }
        changed()
        dataDir.appendLog("chat[\(agent.rawValue)]: message envoyé (\(shown.count) caractères, \(files.count) fichier(s), reprise=\(sessionID != nil))")
        let chat = chats[key(agent)]
        var directory = workDir ?? dataDir.root.appendingPathComponent(agent.workDirName)
        var resume = sessionID
        let active = runner(for: agent)
        active.model = models[agent == .claudeSession ? Agent.claude.rawValue : agent.rawValue]
        active.extraDirectories = Array(Set(files.map { $0.deletingLastPathComponent().path })).sorted()
        active.taskMode = workDir != nil || agent == .claudeSession
        if agent == .claudeSession, let claude = active as? ClaudeRunner {
            // Premier message : on copie la session d'origine ; ensuite on continue la copie.
            claude.forkSource = chat?.sessionID == nil ? chat?.source : nil
            if let cwd = chat?.cwd { directory = URL(fileURLWithPath: cwd) }
            resume = nil
            if let id = chat?.sessionID { resume = id }
        }
        active.send(prompt: prompt, sessionID: resume, workingDirectory: directory)
    }

    func cancel() { runners.values.forEach { $0.cancel() } }

    /// Efface la conversation de l'agent courant.
    func reset() {
        runner(for: agent).cancel()
        let old = chats[key(agent)]
        chats[key(agent)] = AgentChat(sessionID: nil, messages: [], source: old?.source, cwd: old?.cwd, label: old?.label)
        save()
        changed()
    }

    private func runner(for agent: Agent) -> CLIRunner {
        if let existing = runners[agent] { return existing }
        let runner = agent.makeRunner()
        runner.onEvent = { [weak self] in self?.handle($0, from: agent) }
        runners[agent] = runner
        return runner
    }

    private func update(_ agent: Agent, _ change: (inout AgentChat) -> Void) {
        var chat = chats[key(agent)] ?? AgentChat()
        change(&chat)
        chats[key(agent)] = chat
    }

    private func handle(_ event: RunnerEvent, from agent: Agent) {
        switch event {
        case .session(let id):
            update(agent) { $0.sessionID = id }
        case .delta(let text):
            var current = ""
            update(agent) {
                guard var last = $0.messages.last, last.role == .assistant else { return }
                last.text += text
                $0.messages[$0.messages.count - 1] = last
                current = last.text
            }
            changed()
            if agent == self.agent { onReply?(current, false, false) }
        case .finished(let text, let isError):
            update(agent) {
                guard var last = $0.messages.last, last.role == .assistant else { return }
                last.text = text
                last.isError = isError
                $0.messages[$0.messages.count - 1] = last
            }
            save()
            changed()
            dataDir.appendLog("chat[\(agent.rawValue)]: réponse terminée (\(text.count) caractères, erreur=\(isError))")
            if agent == self.agent { onReply?(text, true, isError) }
        }
    }

    private func changed() { NotificationCenter.default.post(name: .chatChanged, object: self) }

    private func save() {
        dataDir.prepare()
        if let data = try? JSONEncoder().encode(Stored(current: agent, chats: chats)) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
