import Foundation

enum RunnerEvent {
    case session(String)
    case delta(String)
    /// Étape d'un travail en cours (outil utilisé, fichier, commande).
    case step(String)
    case finished(text: String, isError: Bool)
}

/// Lance un agent en ligne de commande, lit sa sortie JSON ligne par ligne et émet des événements.
/// Les sous-classes disent quoi lancer et comment lire une ligne.
class CLIRunner {
    var onEvent: ((RunnerEvent) -> Void)?
    /// Mode « tâches » : l'agent travaille dans un dossier et ses actions sensibles passent par le personnage.
    var taskMode = false
    /// Modèle demandé à l'agent (nil : son modèle par défaut).
    var model: String?
    /// Dossiers supplémentaires que l'agent a le droit de lire (fichiers joints).
    var extraDirectories: [String] = []
    private var process: Process?
    private(set) var isRunning = false
    private var wasCancelled = false
    private var timedOut = false
    private var lastActivity = Date()
    private var watchdog: Timer?
    /// Durée sans aucune sortie après laquelle le run est arrêté (les approbations durent au plus ~90 s).
    var idleLimit: TimeInterval { taskMode ? 20 * 60 : 10 * 60 }

    /// État de l'exécution en cours, rempli par `handle`.
    private(set) var streamed = ""
    var finalText: String?
    var finalIsError = false

    // MARK: À redéfinir

    var missingMessage: String { "Agent introuvable sur ce Mac." }
    func locate() -> URL? { nil }
    func arguments(prompt: String, sessionID: String?) -> [String] { [] }
    /// Texte à écrire sur l'entrée standard (nil : rien ; elle est fermée aussitôt).
    func stdinData(prompt: String) -> Data? { nil }
    /// Raison pour laquelle l'agent ne doit pas être lancé (nil : tout va bien).
    var preflightError: String? { nil }
    /// Variables d'environnement ajoutées à celles de l'app.
    var extraEnvironment: [String: String] { [:] }
    func handle(_ object: [String: Any]) {}
    /// Texte final quand aucun résultat exploitable n'est arrivé proprement.
    func resolveFinal(stderr: String, status: Int32) -> (text: String, isError: Bool) {
        if let finalText { return (finalText, finalIsError) }
        if !streamed.isEmpty { return (streamed, false) }
        return ("L'agent s'est arrêté (code \(status)). \(stderr)", true)
    }

    // MARK: Pour les sous-classes

    func appendDelta(_ text: String) {
        streamed += text
        emit(.delta(text))
    }

    func emit(_ event: RunnerEvent) { onEvent?(event) }

    // MARK: Exécution

    func send(prompt: String, sessionID: String?, workingDirectory: URL) {
        guard !isRunning else { return }
        if let problem = preflightError {
            emit(.finished(text: problem, isError: true))
            return
        }
        guard let binary = locate() else {
            emit(.finished(text: missingMessage, isError: true))
            return
        }
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        streamed = ""
        finalText = nil
        finalIsError = false
        wasCancelled = false

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments(prompt: prompt, sessionID: sessionID)
        process.currentDirectoryURL = workingDirectory
        let extra = extraEnvironment
        if !extra.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 } }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        var buffer = Data()
        var errorOutput = Data()
        // La fin se décide quand le processus est terminé ET que les deux flux sont lus jusqu'au bout
        // (plus de délai fixe qui perdrait la dernière ligne). Un petit-enfant qui garde un tube ouvert ne bloque pas plus de 2 s.
        var stdoutDone = false, stderrDone = false, exited: Int32?
        var finished = false
        func finishIfComplete(force: Bool = false) {
            guard !finished, let status = exited, (stdoutDone && stderrDone) || force else { return }
            finished = true
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            self.watchdog?.invalidate()
            self.watchdog = nil
            self.isRunning = false
            self.process = nil
            CLIRunner.active.removeAll { $0 === self }
            let detail = String(data: errorOutput.suffix(400), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let partial = self.streamed.trimmingCharacters(in: .whitespacesAndNewlines)
            if self.timedOut {
                self.emit(.finished(text: (partial.isEmpty ? "" : partial + "\n\n") + "(arrêté : aucune activité depuis \(Int(self.idleLimit / 60)) min)", isError: true))
            } else if self.wasCancelled {
                self.emit(.finished(text: partial.isEmpty ? "(interrompu)" : partial + "\n\n(interrompu)", isError: false))
            } else {
                let final = self.resolveFinal(stderr: detail, status: status)
                self.emit(.finished(text: final.text, isError: final.isError))
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                DispatchQueue.main.async { stdoutDone = true; finishIfComplete() }
                return
            }
            DispatchQueue.main.async {
                self?.lastActivity = Date()
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self?.handle(object) }
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                DispatchQueue.main.async { stderrDone = true; finishIfComplete() }
                return
            }
            DispatchQueue.main.async { self?.lastActivity = Date(); errorOutput.append(chunk) }
        }
        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                exited = proc.terminationStatus
                finishIfComplete()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finishIfComplete(force: true) }
            }
        }

        do {
            try process.run()
        } catch {
            emit(.finished(text: "Impossible de lancer l'agent : \(error.localizedDescription)", isError: true))
            return
        }
        self.process = process
        isRunning = true
        timedOut = false
        lastActivity = Date()
        CLIRunner.active.append(self)
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.isRunning, Date().timeIntervalSince(self.lastActivity) > self.idleLimit else { return }
            self.timedOut = true
            self.killTree()
        }
        if let data = stdinData(prompt: prompt) { stdin.fileHandleForWriting.write(data) }
        try? stdin.fileHandleForWriting.close()
    }

    func cancel() {
        guard isRunning else { return }
        wasCancelled = true
        killTree()
    }

    /// Arrête l'agent ET tout ce qu'il a lancé (commandes, serveurs…) : SIGTERM, puis SIGKILL s'il reste des survivants.
    private func killTree() {
        guard let process, process.isRunning else { return }
        let pids = [process.processIdentifier] + CLIRunner.descendants(of: process.processIdentifier)
        pids.forEach { kill($0, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { pids.forEach { kill($0, SIGKILL) } }
    }

    /// Tous les processus descendants de `root` (via `ps`, car Process ne permet pas de créer un groupe de processus).
    static func descendants(of root: pid_t) -> [pid_t] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        var children: [pid_t: [pid_t]] = [:]
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            let fields = line.split(separator: " ").compactMap { pid_t($0) }
            if fields.count == 2 { children[fields[1], default: []].append(fields[0]) }
        }
        var result: [pid_t] = [], queue = [root]
        while let next = queue.popLast() {
            for child in children[next] ?? [] { result.append(child); queue.append(child) }
        }
        return result
    }

    /// Runs en cours, pour tout arrêter à la fermeture de l'app.
    private static var active: [CLIRunner] = []
    static func terminateAll() { active.forEach { $0.cancel() } }

    /// Premier exécutable trouvé parmi les candidats.
    static func firstExecutable(_ candidates: [String]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static var pathDirectories: [String] {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }
}
