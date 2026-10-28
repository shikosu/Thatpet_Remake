import Foundation

enum RunnerEvent {
    case session(String)
    case delta(String)
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

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self?.handle(object) }
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { errorOutput.append(chunk) }
        }
        process.terminationHandler = { [weak self] proc in
            // On laisse arriver les dernières lectures, planifiées sur le main.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                let detail = String(data: errorOutput.suffix(400), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if self.wasCancelled {
                    let partial = self.streamed.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.emit(.finished(text: partial.isEmpty ? "(interrompu)" : partial + "\n\n(interrompu)", isError: false))
                    return
                }
                let final = self.resolveFinal(stderr: detail, status: proc.terminationStatus)
                self.emit(.finished(text: final.text, isError: final.isError))
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
        if let data = stdinData(prompt: prompt) { stdin.fileHandleForWriting.write(data) }
        try? stdin.fileHandleForWriting.close()
    }

    func cancel() {
        guard isRunning else { return }
        wasCancelled = true
        process?.terminate()
    }

    /// Premier exécutable trouvé parmi les candidats.
    static func firstExecutable(_ candidates: [String]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static var pathDirectories: [String] {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }
}
