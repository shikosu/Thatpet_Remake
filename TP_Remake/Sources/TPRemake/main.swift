import AppKit

/// Cherche le dossier des packs : --packs <dir>, sinon ./Resources/packs, sinon le bundle de l'app.
func packsDirectory() -> URL {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--packs"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]) }
    let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/packs")
    if FileManager.default.fileExists(atPath: local.path) { return local }
    return Bundle.main.resourceURL?.appendingPathComponent("packs") ?? local
}

// MARK: - Ligne de commande (hook, connect, disconnect, status)

func runCommandLine(_ args: [String]) -> Int32? {
    guard args.count > 1 else { return nil }
    let dataDir = DataDir.resolve()
    let rest = Array(args.dropFirst(2))
    /// Valeur d'une option « --nom valeur ».
    func option(_ name: String) -> String? {
        guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { return nil }
        return rest[i + 1]
    }
    /// Arguments positionnels (sans les options et leurs valeurs).
    func positional() -> [String] {
        var out: [String] = [], skip = false
        for a in rest {
            if skip { skip = false; continue }
            if ["--config-dir", "--agent", "--packs", "--session", "--cwd", "--label", "--dir", "--model", "--attach", "--cancel-after", "--seconds", "--seed", "--width", "--height", "--character", "--then", "--screen", "--size"].contains(a) { skip = true; continue }
            if !a.hasPrefix("--") { out.append(a) }
        }
        return out
    }
    func configDir(for agent: Agent) -> URL {
        if let dir = option("--config-dir") { return URL(fileURLWithPath: dir) }
        return agent == .claude ? AgentConnector.defaultConfigDir : AgentConnector.defaultAntigravityDir
    }
    let binary = Bundle.main.executablePath ?? URL(fileURLWithPath: args[0]).standardizedFileURL.path

    switch args[1] {
    case "hook":
        return HookMode.run(arguments: rest, dataDir: dataDir)
    case "gate":
        // Appelé par les runs de Claude Code lancés par le personnage (hook PreToolUse en ligne).
        var payload: [String: Any] = [:]
        if isatty(STDIN_FILENO) == 0,
           let object = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any] { payload = object }
        return HookMode.gate(provider: option("--provider") ?? "claude", payload: payload, dataDir: dataDir)
    case "connect", "disconnect":
        // Par défaut : Claude Code. Antigravity doit être demandé explicitement.
        let name = positional().first ?? "claude"
        guard let agent = Agent(rawValue: name), Agent.primary.contains(agent) else {
            FileHandle.standardError.write(Data("Agent inconnu : \(name) (claude ou antigravity)\n".utf8))
            return 2
        }
        do {
            let dir = configDir(for: agent)
            switch (args[1], agent) {
            case ("connect", .claude): print(try AgentConnector.connect(configDir: dir, binary: binary))
            case ("connect", .antigravity): print(try AgentConnector.connectAntigravity(configDir: dir, binary: binary))
            case (_, .claude): print(try AgentConnector.disconnect(configDir: dir))
            case (_, .antigravity): print(try AgentConnector.disconnectAntigravity(configDir: dir))
            default: return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Erreur : \(error)\n".utf8))
            return 1
        }
    case "status":
        print("claude:      " + (AgentConnector.isConnected(configDir: configDir(for: .claude)) ? "connecté" : "non connecté"))
        print("antigravity: " + (AgentConnector.isAntigravityConnected(configDir: configDir(for: .antigravity)) ? "connecté" : "non connecté"))
        return 0
    case "ask":
        // Test du chat sans interface : TPRemake ask [--agent claude|antigravity] "message".
        let text = positional().joined(separator: " ")
        guard !text.isEmpty || option("--attach") != nil else { print("usage : TPRemake ask [--agent claude|antigravity] \"message\""); return 2 }
        var agent = option("--agent").flatMap(Agent.init(rawValue:))
        let model = ChatModel(dataDir: dataDir, agent: agent)
        if let m = option("--model") { model.models[(agent ?? .claude).rawValue] = m }
        if let file = option("--attach") { model.attach([URL(fileURLWithPath: file)]) }
        if let dir = option("--dir") { model.setWorkDir(URL(fileURLWithPath: dir)) }   // mode tâches
        // Session en cours : --session <id> --cwd <dossier> [--label nom]
        if let session = option("--session"), let cwd = option("--cwd") {
            model.attachLive(sessionID: session, cwd: cwd, label: option("--label") ?? URL(fileURLWithPath: cwd).lastPathComponent)
            agent = .claudeSession
        }
        guard agent != .claudeSession || model.agent == .claudeSession else {
            print("--agent claudeSession demande --session <id> --cwd <dossier>"); return 2
        }
        var lastStreamed = ""
        model.onReply = { reply, isFinal, isError in
            guard isFinal else { lastStreamed = reply; return }
            // Contrôle : le texte reçu en flux doit être celui du résultat final.
            if !lastStreamed.isEmpty, lastStreamed.trimmingCharacters(in: .whitespacesAndNewlines) != reply.trimmingCharacters(in: .whitespacesAndNewlines) {
                FileHandle.standardError.write(Data("[avertissement] le flux diffère du résultat final\n".utf8))
            }
            print(reply.trimmingCharacters(in: .whitespacesAndNewlines))
            exit(isError ? 1 : 0)
        }
        model.send(text)
        if let delay = option("--cancel-after").flatMap(Double.init) {   // test de l'annulation
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { model.cancel() }
        }
        RunLoop.main.run()
        return 0
    case "sizes":
        // Tableau des tailles pour une largeur d'écran (points) : TPRemake sizes [--screen 1470].
        let width = option("--screen").flatMap { Double($0) }.map { CGFloat($0) } ?? NSScreen.main?.frame.width ?? 1440
        print(String(format: "Écran de %.0f pt : facteur %.3f", width, PetSizing.displayFactor(screenWidth: width)))
        for level in PetSizing.levels {
            let applied = PetSizing.applied(size: level.value, screenWidth: width)
            let canvas = PetSizing.canvasPoints(size: level.value, screenWidth: width, standHeight: 0.76)
            print(String(format: "  %-7@ %.2f → appliquée %.2f → cadre %.0f pt, personnage debout ≈ %.0f pt", level.name as NSString, level.value, applied, canvas, canvas * 0.76))
        }
        return 0
    case "characters":
        let bundled = packsDirectory()
        for c in PackLibrary.discover(bundled: bundled, dataDir: dataDir) { print("\(c.id)\t\(c.name)\t[\(c.source)]\t\(c.directory.path)") }
        return 0
    case "sim":
        // Simulation sans écran du comportement du personnage (voir Simulation.swift).
        return runSimulation(seconds: option("--seconds").flatMap(Double.init) ?? 1800,
                             seed: option("--seed").flatMap(UInt64.init) ?? 1,
                             packs: PackLibrary.find(option("--character") ?? "opus55", bundled: packsDirectory(), dataDir: dataDir)?.directory
                                 ?? packsDirectory().appendingPathComponent("opus55"),
                             width: option("--width").flatMap { Double($0) }.map { CGFloat($0) } ?? 1440,
                             height: option("--height").flatMap { Double($0) }.map { CGFloat($0) } ?? 790,
                             switchTo: option("--then").flatMap { PackLibrary.find($0, bundled: packsDirectory(), dataDir: dataDir)?.directory },
                             size: option("--size").flatMap { Double($0) }.map { CGFloat($0) } ?? 256)
    case "fx-test":
        return runFxTests()
    case "reactions-test":
        return runReactionTests(packs: PackLibrary.find(option("--character") ?? "opus55", bundled: packsDirectory(), dataDir: dataDir)?.directory
                                    ?? packsDirectory().appendingPathComponent("opus55"))
    case "particles-test":
        return runParticleTests(packs: PackLibrary.find(option("--character") ?? "opus55", bundled: packsDirectory(), dataDir: dataDir)?.directory
                                    ?? packsDirectory().appendingPathComponent("opus55"))
    case "attach-test":
        // Collage/dépôt : presse-papiers privés (celui de l'utilisateur n'est pas touché).
        let model = ChatModel(dataDir: DataDir(root: URL(fileURLWithPath: "/tmp/tpattach-test")))
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "ÉCHEC ") + what); if !ok { failures += 1 } }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let a = NSPasteboard(name: .init("tpremake.test.a")); a.clearContents(); a.setData(png, forType: .png)
        check(ChatModel.hasAttachable(a), "PNG reconnu")
        check(model.attach(from: a), "PNG joint")
        let b = NSPasteboard(name: .init("tpremake.test.b")); b.clearContents(); b.setData(image.tiffRepresentation!, forType: .tiff)
        check(model.attach(from: b), "TIFF converti en PNG")
        let file = URL(fileURLWithPath: "/tmp/tpattach-test/note.txt")
        try? "x".write(to: file, atomically: true, encoding: .utf8)
        let c = NSPasteboard(name: .init("tpremake.test.c")); c.clearContents(); c.writeObjects([file as NSURL])
        check(model.attach(from: c), "fichier joint")
        let d = NSPasteboard(name: .init("tpremake.test.d")); d.clearContents(); d.setString("juste du texte", forType: .string)
        check(!ChatModel.hasAttachable(d) && !model.attach(from: d), "texte seul ignoré (collage normal)")
        check(model.attachments.count == 3, "3 pièces jointes (\(model.attachments.count))")
        let images = model.attachments.filter { $0.pathExtension == "png" }
        check(images.count == 2 && images.allSatisfy { NSImage(contentsOf: $0)?.size.width == 20 }, "images relisibles")
        model.clearAttachments()
        check(model.attachments.isEmpty, "retrait")
        print(failures == 0 ? "OK" : "\(failures) échec(s)")
        return failures == 0 ? 0 : 1
    case "md-debug":
        for line in Markdown.describe(Markdown.render(positional().joined(separator: " "))) { print(line) }
        return 0
    case "help", "--help", "-h":
        print("""
        TPRemake                                         lance le personnage
        TPRemake ask [--agent A] "message"               discute avec un agent depuis le terminal (A = claude | antigravity)
        TPRemake ask --dir DIR [--agent A] "tâche"       confie une tâche à l'agent dans le dossier DIR (actions validées par le personnage)
        TPRemake ask --session ID --cwd DIR "message"    discute avec une copie d'une session Claude Code ouverte
        TPRemake connect|disconnect [claude|antigravity] [--config-dir DIR]
        TPRemake status [--config-dir DIR]
        TPRemake hook --provider A [--event NAME]        (appelé par l'agent)
        """)
        return 0
    default:
        return nil   // arguments du type --packs : on lance l'app
    }
}

if let code = runCommandLine(CommandLine.arguments) { exit(code) }

// MARK: - Application

/// Session Claude Code vue par les hooks (VS Code, terminal…).
struct LiveSession {
    let id: String
    let cwd: String
    var lastSeen: Date
    var name: String { URL(fileURLWithPath: cwd).lastPathComponent }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panel: NSPanel!
    private var view: PetView!
    private var player: AnimationPlayer!
    private var brain: PetBrain!
    private var pack: Pack!
    private var statusItem: NSStatusItem!
    private let dataDir = DataDir.resolve()
    private var settings = Settings()
    private var characters: [CharacterInfo] = []
    private let listener = PetSocket.Listener()
    private var idleTimer: Timer?
    private var tickTimer: Timer?
    private var tickCount = 0
    private var lastState = "idle"
    private var chat: ChatModel!
    private var bubble: BubbleController!
    private var chatWindow: ChatWindowController!
    private var approvals: ApprovalController!
    private var liveSessions: [String: LiveSession] = [:]
    private var agyModelCache: [(id: String, name: String)]?
    /// Un menu (clic droit ou icône de la barre des menus) est ouvert : le personnage ne bouge pas.
    private var menuOpen = false
    private let particles = ParticleSystem(seed: UInt64.random(in: 1...UInt64.max))
    private let reactions = ReactionEngine(seed: UInt64.random(in: 1...UInt64.max))
    private var activity: ActivityBubble!

    /// Géométrie du personnage en coordonnées de la fenêtre, pour placer les particules.
    private func particleFrame() -> ParticleSystem.Frame {
        let origin = brain.position
        return ParticleSystem.Frame(figure: brain.figure.offsetBy(dx: -origin.x, dy: -origin.y),
                                    floorY: brain.world.minY - origin.y, unit: CGFloat(player.unit))
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard PetLock.acquire(dataDir) else {
            FileHandle.standardError.write(Data("TPRemake tourne déjà.\n".utf8))
            NSApp.terminate(nil)
            return
        }
        settings = Settings.load(dataDir)
        characters = PackLibrary.discover(bundled: packsDirectory(), dataDir: dataDir)
        // Personnage choisi ; s'il a disparu ou ne se charge pas, retour à opus55 (inclus).
        let wanted = characters.first { $0.id == settings.character }
        if let wanted, let loaded = try? Pack.load(from: wanted.directory) {
            pack = loaded
        } else {
            do { pack = try Pack.load(from: packsDirectory().appendingPathComponent("opus55")) } catch {
                FileHandle.standardError.write(Data("Erreur : \(error)\n".utf8))
                NSApp.terminate(nil)
                return
            }
            if wanted != nil || settings.character != "opus55" { dataDir.appendLog("personnage « \(settings.character) » indisponible, retour à opus55") }
        }

        let start = visibleFrame(around: NSEvent.mouseLocation)
        let side = canvasSide(at: NSEvent.mouseLocation)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: PetGeometry.windowSize(forCanvas: side)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        view = PetView(frame: NSRect(origin: .zero, size: panel.frame.size))
        view.canvasSide = side
        view.menuProvider = { [unowned self] in makeMenu() }
        view.onDrop = { [unowned self] pasteboard in
            guard chat.attach(from: pasteboard) else { return false }
            bubble.showInput()   // le message part avec les fichiers déposés
            return true
        }
        view.onClick = { [unowned self] in bubble.toggleInput() }
        view.onDragStart = { [unowned self] p in brain.beginDrag(at: p, now: now) }
        view.onDragMove = { [unowned self] p in brain.dragMoved(to: p, now: now) }
        view.onDragEnd = { [unowned self] p in brain.endDrag(at: p, world: visibleFrame(around: p), now: now) }
        panel.contentView = view

        player = AnimationPlayer(pack: pack)
        player.onFrame = { [weak self] in self?.view.show($0) }
        brain = PetBrain(pack: pack, player: player, size: side, world: start, seed: UInt64.random(in: 1...UInt64.max), now: now)
        brain.wander = settings.wander
        panel.setFrameOrigin(brain.position)
        panel.orderFrontRegardless()
        player.onStart = { [unowned self] _, parts in particles.animationStarted(particles: parts, now: now, frame: particleFrame()) }

        chat = ChatModel(dataDir: dataDir)
        chat.models = settings.models
        chat.pruneAttachments()
        if let dir = settings.workDir, FileManager.default.fileExists(atPath: dir) { chat.setWorkDir(URL(fileURLWithPath: dir)) }
        chatWindow = ChatWindowController(model: chat)
        let figure = { [unowned self] in brain.figure }
        bubble = BubbleController(model: chat, anchor: panel, figure: figure) { [unowned self] in chatWindow.show() }
        activity = ActivityBubble(anchor: panel, figure: figure)
        activity.enabled = settings.activityBubble
        particles.enabled = settings.particles
        reactions.rareChance = settings.rareChance
        approvals = ApprovalController(anchor: panel, figure: figure, dataDir: dataDir) { [unowned self] in bubble.frame }
        approvals.onDecision = { [unowned self] decision in
            apply(state: decision == .allow ? "working" : "thinking")
        }
        chat.onReply = { [unowned self] text, isFinal, isError in
            bubble.showReply(text, isFinal: isFinal, isError: isError)
            if isFinal { apply(state: isError ? "error" : "celebrating") } else if lastState != "thinking" { apply(state: "thinking") }
        }
        // Le personnage reste en place tant que l'utilisateur discute ou doit répondre.
        brain.hold = { [unowned self] in bubble.isVisible || approvals.pendingCount > 0 || chat.isBusy || menuOpen }

        installMainMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        dataDir.appendLog("personnage : \(pack.id)")
        let listening = listener.start(at: dataDir.socket) { [weak self] data in self?.receive(data) }
        dataDir.appendLog(listening ? "started, listening on \(dataDir.socket.path)" : "started, socket unavailable")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "🐾"
        let menu = NSMenu()
        menu.delegate = self   // reconstruit à chaque ouverture (sessions, état du chat)
        statusItem.menu = menu

        if let test = ProcessInfo.processInfo.environment["TPREMAKE_SELFTEST"] {
            if test == "react" { runReactionSelfTest() } else if test == "pointer" { runPointerTest() } else if test == "drag" { runDragTest() } else if test == "size" { runSizeTest() } else { runSelfTest() }
        }

        // Boucle d'animation : 60 Hz en mouvement, 30 Hz à l'arrêt. Mode .common pour continuer pendant un menu.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// Diagnostic (TPREMAKE_SELFTEST=react) : injecte une suite d'événements d'agent et mesure la vraie réaction.
    private func runReactionSelfTest() {
        func log(_ text: String) { dataDir.appendLog("selftest: " + text) }
        brain.wander = false
        reactions.rareChance = 0
        reactions.escalateAfter = 1.2
        func send(_ event: String, tool: String? = nil, reply: Bool = false) {
            var message = AgentMessage(provider: "claude", event: event, state: AgentEvents.state(for: event) ?? "idle", session: "selftest", tool: tool)
            if reply { message.reply = "/nonexistent.sock"; message.expires = Date().timeIntervalSince1970 + 30; message.detail = "rm -rf x" }
            if let data = try? JSONEncoder().encode(message) { receive(data) }
        }
        func ms(_ block: () -> Void) -> Double {
            let t0 = ProcessInfo.processInfo.systemUptime; block()
            return (ProcessInfo.processInfo.systemUptime - t0) * 1000
        }
        func snapshot(_ label: String) {
            let sprites = particles.sprites(now: now, frame: particleFrame())
            let shapes = Set(sprites.map { String(describing: $0.shape) }).sorted().joined(separator: ",")
            let fade = player.crossfade(now: now)
            let cost = ms { view.renderParticles(sprites) }
            let drawn = view.renderedParticleCount
            log(String(format: "%@ → animation « %@ » | particules %d dessinées %d [%@] (%.2f ms) | fondu %@ | bulle « %@ » visible=%d",
                       label, player.current, sprites.count, drawn, shapes, cost,
                       fade.map { String(format: "%.2f", $0.progress) } ?? "—", activity.text, activity.isVisible ? 1 : 0))
        }
        let steps: [(Double, () -> Void)] = [
            (1.0, { send("PreToolUse", tool: "Bash") }), (1.5, { snapshot("outil Bash") }),
            (2.0, { send("UserPromptSubmit") }), (2.05, { snapshot("réflexion +0,05 s (fondu attendu)") }), (2.6, { snapshot("réflexion +0,6 s") }),
            (3.0, { send("PermissionRequest", tool: "Bash", reply: true) }), (3.3, { snapshot("attention") }), (4.5, { snapshot("attention +1,5 s (urgente attendue)") }),
            (5.0, { self.approvals.dismissAll() ; send("PreToolUse", tool: "Edit") }), (5.2, { snapshot("après réponse (merci attendu)") }), (7.5, { snapshot("merci terminé (working attendu)") }),
            (8.0, { send("Stop") }), (8.25, { snapshot("fin de tour (confettis attendus)") }), (12.0, { snapshot("confettis finis") }),
            (12.5, { send("PostToolUseFailure", tool: "Bash") }), (12.8, { snapshot("échec d'outil (oops + sueur attendus)") }),
            (14.5, { send("SessionEnd") }), (15.5, { snapshot("session terminée") }), (15.6, { log("fin du test de réactions") }),
        ]
        for (delay, action) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() } }
    }

    /// Diagnostic (TPREMAKE_SELFTEST=size) : passe par tous les niveaux de taille et mesure la vraie fenêtre.
    private func runSizeTest() {
        func log(_ text: String) { dataDir.appendLog("selftest: " + text) }
        brain.wander = false
        var levels = PetSizing.levels.map { $0 }
        levels.append(("Normal", 1.0))   // retour à la taille de départ
        var i = 0
        func next() {
            guard i < levels.count else { log("fin du test de taille"); return }
            let level = levels[i]; i += 1
            settings.size = level.value
            applySize()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                let f = brain.figure
                let screenW = NSScreen.main?.frame.width ?? 0
                let expected = PetSizing.canvasPoints(size: level.value, screenWidth: screenW, standHeight: pack.standHeight,
                                                      maxCanvas: PetBrain.maxCanvas(pack: pack, world: brain.world))
                let inZone = f.minX >= brain.world.minX - 1 && f.maxX <= brain.world.maxX + 1 && f.maxY <= brain.world.maxY + 1 && f.minY >= brain.world.minY - 1
                log(String(format: "%@ (%.2f) : fenêtre %.0f × %.0f pt (attendu %.0f) | personnage %.0f × %.0f pt | au sol=%d dans la zone=%d | mode %@",
                           level.name as NSString, level.value, panel.frame.width, panel.frame.height, expected, f.width, f.height,
                           abs(f.minY - brain.world.minY) < 1.5 ? 1 : 0, inZone ? 1 : 0, brain.mode.name as NSString))
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next() }
    }

    /// Diagnostic (TPREMAKE_SELFTEST=drag) : saisit le personnage et le déplace vers la droite, la gauche, puis s'arrête.
    /// Le pointeur est vraiment déplacé ; les appuis sont envoyés à la vue (pas d'autorisation d'accessibilité requise).
    private func runDragTest() {
        func log(_ text: String) { dataDir.appendLog("selftest: " + text) }
        let original = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        func warp(_ p: NSPoint) { CGWarpMouseCursorPosition(CGPoint(x: p.x, y: screenHeight - p.y)) }
        func fake(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        brain.wander = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            // Un point opaque près du centre du personnage.
            var start: NSPoint?
            let f = brain.figure
            outer: for dy in stride(from: 0, to: f.height / 2, by: 6) {
                for sign in [CGFloat(1), -1] {
                    let p = NSPoint(x: f.midX, y: f.midY + sign * dy)
                    if view.isOpaque(at: view.convert(panel.convertPoint(fromScreen: p), from: nil)) { start = p; break outer }
                }
            }
            guard var pointer = start else { log("pas de point de saisie"); return }
            warp(pointer)
            updatePointer()
            view.mouseDown(with: fake(.leftMouseDown))
            var frame = 0
            let phases: [(label: String, dx: CGFloat, frames: Int)] = [("vers la gauche", -12, 40), ("vers la droite", 12, 40), ("arrêt", 0, 40)]
            var phase = 0, inPhase = 0
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [self] t in
                frame += 1
                let ph = phases[phase]
                pointer.x += ph.dx
                warp(pointer)
                view.mouseDragged(with: fake(.leftMouseDragged))
                inPhase += 1
                if inPhase == ph.frames {
                    let f = brain.figure
                    log(String(format: "glisser %@ : animation « %@ » | mode %@ | haut du personnage %.1f pt sous le pointeur", ph.label as NSString, player.current as NSString, brain.mode.name as NSString, pointer.y - f.maxY))
                    phase += 1; inPhase = 0
                    if phase == phases.count {
                        t.invalidate()
                        view.mouseUp(with: fake(.leftMouseUp))
                        warp(original)
                        log("relâché : mode \(brain.mode.name)")
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Diagnostic (TPREMAKE_SELFTEST=pointer) : déplace le pointeur et vérifie le passage des clics et l'arrêt au survol.
    private func runPointerTest() {
        func log(_ text: String) { dataDir.appendLog("selftest: " + text) }
        let original = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        func warp(_ p: NSPoint) { CGWarpMouseCursorPosition(CGPoint(x: p.x, y: screenHeight - p.y)) }
        func opaque(_ p: NSPoint) -> Bool { view.isOpaque(at: view.convert(panel.convertPoint(fromScreen: p), from: nil)) }
        /// Premier point de la grille (centre d'abord) dont le pixel est opaque / transparent.
        func find(in rect: NSRect, wantOpaque: Bool, margin: CGFloat = 0) -> NSPoint? {
            var best: (NSPoint, CGFloat)?
            for x in stride(from: rect.minX, to: rect.maxX, by: 6) {
                for y in stride(from: rect.minY, to: rect.maxY, by: 6) {
                    let p = NSPoint(x: x, y: y)
                    guard opaque(p) == wantOpaque else { continue }
                    // Pour le survol, on veut un point bien à l'intérieur du personnage.
                    if wantOpaque, margin > 0, ![(-margin, 0), (margin, 0), (0, -margin), (0, margin)].allSatisfy({ opaque(NSPoint(x: x + $0.0, y: y + $0.1)) }) { continue }
                    let d = hypot(x - rect.midX, y - rect.midY)
                    if best == nil || d < best!.1 { best = (p, d) }
                }
            }
            return best?.0
        }
        func state(_ label: String) {
            log("pointeur \(label) : fenêtre capte les clics=\(panel.ignoresMouseEvents ? 0 : 1) survol=\(brain.hover ? 1 : 0)")
        }

        brain.wander = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            guard let onPet = find(in: brain.figure, wantOpaque: true), let inWindowClear = find(in: panel.frame, wantOpaque: false) else {
                log("pas de point de test trouvé"); return
            }
            warp(onPet)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                state("sur le personnage          (attendu : 1 / 1)")
                warp(inWindowClear)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                    state("zone transparente fenêtre (attendu : 0 / 0)")
                    warp(NSPoint(x: 5, y: panel.frame.midY))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                        state("hors de la fenêtre        (attendu : 0 / 0)")
                        waitForWalk(deadline: Date().addingTimeInterval(60), find: find, warp: warp, log: log) {
                            warp(NSPoint(x: original.x, y: original.y)); log("fin du test")
                        }
                    }
                }
            }
        }
    }

    /// Attend que le personnage marche ou grimpe, pose le pointeur dessus et vérifie qu'il s'arrête, puis repart.
    private func waitForWalk(deadline: Date, find: @escaping (NSRect, Bool, CGFloat) -> NSPoint?, warp: @escaping (NSPoint) -> Void,
                             log: @escaping (String) -> Void, done: @escaping () -> Void) {
        let moving = ["walking", "toWall", "climbing", "ceiling"].contains(brain.mode.name)
        guard moving, let point = find(brain.figure, true, 10) else {
            if Date() > deadline { log("personnage jamais en déplacement : test du survol abandonné"); done(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in waitForWalk(deadline: deadline, find: find, warp: warp, log: log, done: done) }
            return
        }
        let mode = brain.mode.name
        warp(point)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            let frozen = brain.position
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                let held = brain.position == frozen && brain.mode.name == mode
                log("survol d'un personnage en « \(mode) » : immobile pendant 1,2 s = \(held ? "oui" : "NON") (mode \(brain.mode.name))")
                warp(NSPoint(x: 5, y: panel.frame.midY))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                    log("après avoir quitté le personnage : repart = \(brain.position != frozen ? "oui" : "NON")")
                    done()
                }
            }
        }
    }

    /// Diagnostic (TPREMAKE_SELFTEST=1) : mesure l'ouverture de la bulle, le focus, le coût du menu et d'une image.
    private func runSelfTest() {
        func ms(_ block: () -> Void) -> Double {
            let t0 = ProcessInfo.processInfo.systemUptime; block()
            return (ProcessInfo.processInfo.systemUptime - t0) * 1000
        }
        func log(_ text: String) { dataDir.appendLog("selftest: " + text) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            log(String(format: "menu clic droit : %.1f ms (x3: %.1f %.1f %.1f)", ms { _ = makeMenu() }, ms { _ = makeMenu() }, ms { _ = makeMenu() }, ms { _ = makeMenu() }))
            log(String(format: "isOpaque(point) : %.3f ms", ms { for _ in 0..<100 { _ = view.isOpaque(at: NSPoint(x: 100, y: 100)) } } / 100))
            var ticks = 0.0
            let n = 120
            for _ in 0..<n { ticks += ms { brain.tick(now: now); view.apply(player.transform(now: now)) } }
            log(String(format: "tick (cerveau + vue) : %.3f ms en moyenne", ticks / Double(n)))
            let opening = ms { bubble.toggleInput() }
            log(String(format: "ouverture de la bulle : %.1f ms | visible=%d", opening, bubble.isVisible ? 1 : 0))
            // Focus : la bulle doit rendre le clavier à l'application qui l'avait.
            let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                let pasteOK = NSApp.target(forAction: #selector(NSText.paste(_:)), to: nil, from: nil) != nil
                let duringApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                log("coller (Cmd+V) disponible dans la bulle = \(pasteOK ? "oui" : "NON") | premier plan pendant la bulle : \(duringApp)")
                bubble.toggleInput()   // second « clic » : ferme et rend le focus
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                    log("premier plan avant : \(before) | après fermeture : \(after) | rendu = \(after == before ? "oui" : "NON")")
                }
            }
            for delay in [0.05, 0.3, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                    log(String(format: "bulle +%.2fs : visible=%d key=%d appActive=%d", delay, bubble.isVisible ? 1 : 0, bubble.debugIsKey ? 1 : 0, NSApp.isActive ? 1 : 0))
                }
            }
        }
    }

    private func tick() {
        updatePointer()   // à chaque image : un clic ne doit jamais tomber à côté
        tickCount += 1
        if !brain.isMoving && tickCount % 2 == 1 { return }
        let t = now
        brain.tick(now: t)
        let p = brain.position
        let origin = NSPoint(x: (p.x * 2).rounded() / 2, y: (p.y * 2).rounded() / 2)
        if origin != panel.frame.origin {
            panel.setFrameOrigin(origin)
            bubble.followPet()
            approvals.followPet()
        }
        view.apply(player.transform(now: t))
        activity.follow()
        activity.suppressed = bubble.isVisible || approvals.pendingCount > 0
        perform(reactions.tick(now: t, has: { [pack] in pack?.animations[$0] != nil }))   // escalade d'attention, rappels
        view.setCrossfade(player.crossfade(now: t))
        view.renderParticles(particles.sprites(now: t, frame: particleFrame()))
    }

    /// Côté du cadre du personnage pour la taille choisie, sur l'écran qui contient `point`.
    private func canvasSide(at point: NSPoint) -> CGFloat {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        return PetSizing.canvasPoints(size: settings.size, screenWidth: screen?.frame.width ?? 1440,
                                      standHeight: pack.standHeight, maxCanvas: PetBrain.maxCanvas(pack: pack, world: visible))
    }

    /// Applique la taille choisie (réglage, changement de personnage ou d'écran).
    private func applySize() {
        let f = brain.figure
        let side = canvasSide(at: NSPoint(x: f.midX, y: f.midY))
        guard side != brain.size else { return }
        panel.setContentSize(PetGeometry.windowSize(forCanvas: side))
        view.canvasSide = side
        particles.clear()
        brain.resize(to: side, now: now)
        panel.setFrameOrigin(brain.position)
        bubble.followPet(); approvals.followPet()
        dataDir.appendLog("taille : \(PetSizing.label(for: settings.size)) (\(Int(side)) pt)")
    }

    /// Zone utilisable (hors barre des menus et Dock) de l'écran qui contient le point.
    private func visibleFrame(around point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
    }

    @objc private func screensChanged() {
        let f = brain.figure
        brain.worldChanged(visibleFrame(around: NSPoint(x: f.midX, y: f.midY)), now: now)
        applySize()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fillMenu(menu)
    }

    /// Message d'un hook : on traduit l'état en animation.
    private func receive(_ data: Data) {
        guard let message = try? JSONDecoder().decode(AgentMessage.self, from: data) else { return }
        dataDir.appendLog("event \(message.provider)/\(message.event) -> \(message.state) session=\(message.session)" + (message.cwd.map { " cwd=\($0)" } ?? ""))
        apply(state: message.state)
        showActivity(message)
        trackSession(message)
        if message.event == "PermissionRequest", let reply = message.reply, let expires = message.expires {
            approvals.enqueue(.init(tool: message.tool ?? "outil", detail: message.detail ?? "",
                                    replyPath: reply, expires: Date(timeIntervalSince1970: expires)))
            approvals.autoAnswerIfRequested()
        }
    }

    /// Retient les sessions Claude Code actives pour pouvoir en proposer une copie dans le chat.
    private func trackSession(_ message: AgentMessage) {
        guard message.provider == "claude", message.session != "default" else { return }
        if message.event == "SessionEnd" { liveSessions.removeValue(forKey: message.session); return }
        guard let cwd = message.cwd else { return }
        liveSessions[message.session] = LiveSession(id: message.session, cwd: cwd, lastSeen: Date())
    }

    /// Sessions à proposer : récentes, et pas celles que nos propres chats ont créées.
    private func selectableSessions() -> [LiveSession] {
        let limit = Date().addingTimeInterval(-6 * 3600)
        return liveSessions.values
            .filter { $0.lastSeen > limit && !chat.isOwnSession($0.id) }
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(5).map { $0 }
    }

    /// Réaction à un état d'agent : le moteur choisit l'animation (attention, merci, surprise rare…) et les sons.
    private func apply(state: String) {
        lastState = state
        perform(reactions.react(to: state, now: now, has: { [pack] in pack?.animations[$0] != nil }))
        armIdleTimer(afterState: state)
    }

    private func perform(_ result: ReactionEngine.Result) {
        if case .play(let animation) = result.change { brain.agentState(animation, now: now) }
        if settings.sounds { for name in result.sounds { NSSound(named: name)?.play() } }
    }

    /// Si l'agent n'envoie plus rien, on revient au repos (sauf si une approbation attend votre réponse).
    private func armIdleTimer(afterState state: String) {
        idleTimer?.invalidate()
        guard state != "idle" && state != "stop" else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            guard let self else { return }
            if approvals.pendingCount > 0 { armIdleTimer(afterState: state); return }
            apply(state: "idle")
        }
    }

    /// Bulle d'activité : ce que fait l'agent.
    private func showActivity(_ message: AgentMessage) {
        guard message.provider != "claude" || !chat.isOwnSession(message.session) else { return }   // pas pour nos propres chats
        if let text = AgentEvents.bubbleText(state: message.state, tool: message.tool) {
            activity.show(text, persistent: message.state == "attention")
        } else {
            activity.hide()
        }
    }

    /// Regarde où est le pointeur. Sur un pixel opaque : la fenêtre capte les clics et le personnage s'arrête
    /// pour se laisser cliquer ; ailleurs (y compris les zones transparentes de la fenêtre) les clics la traversent.
    /// C'est échantillonné à chaque image plutôt que déduit d'événements, qui n'arrivent pas toujours.
    private func updatePointer() {
        let dragging = brain.mode.name == "dragging"
        let inView = view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let over = view.isOpaque(at: inView)
        let engaged = over || view.isPressed || dragging
        brain.hover = engaged && !dragging
        panel.ignoresMouseEvents = !engaged
    }

    /// Menu minimal : sans lui, Cmd+V / Cmd+C / Cmd+A ne fonctionnent pas dans le champ de saisie.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quitter TPRemake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Édition")
        edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        fillMenu(menu)
        return menu
    }

    private func fillMenu(_ menu: NSMenu) {
        func add(_ title: String, _ action: Selector?, enabled: Bool = true, checked: Bool = false, to target: NSMenu? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled && action != nil
            item.state = checked ? .on : .off
            (target ?? menu).addItem(item)
        }
        for (agent, connected) in [(Agent.claude, AgentConnector.isConnected(configDir: AgentConnector.defaultConfigDir)),
                                   (Agent.antigravity, AgentConnector.isAntigravityConnected(configDir: AgentConnector.defaultAntigravityDir))] {
            add("\(agent.displayName) : hooks \(connected ? "connectés" : "non connectés")", nil)
        }

        let agentMenu = NSMenuItem(title: "Discuter avec", action: nil, keyEquivalent: "")
        let agentSub = NSMenu()
        for agent in Agent.primary {
            let item = NSMenuItem(title: agent.displayName, action: #selector(selectAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.rawValue
            item.state = agent == chat.agent ? .on : .off
            agentSub.addItem(item)
        }
        agentSub.addItem(.separator())
        let header = NSMenuItem(title: "Copie d'une session Claude Code ouverte :", action: nil, keyEquivalent: "")
        header.isEnabled = false
        agentSub.addItem(header)
        let sessions = selectableSessions()
        if sessions.isEmpty {
            let none = NSMenuItem(title: "  (aucune session détectée)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            agentSub.addItem(none)
        }
        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale(identifier: "fr_FR")
        for session in sessions {
            let item = NSMenuItem(title: "  \(session.name) — \(relative.localizedString(for: session.lastSeen, relativeTo: Date()))",
                                  action: #selector(selectLiveSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.id
            item.state = chat.agent == .claudeSession && chat.liveSource == session.id ? .on : .off
            agentSub.addItem(item)
        }
        agentMenu.submenu = agentSub
        menu.addItem(agentMenu)

        let dirTitle = chat.workDir.map { "Dossier de travail : \($0.lastPathComponent)" } ?? "Dossier de travail : aucun"
        let dirMenu = NSMenuItem(title: dirTitle, action: nil, keyEquivalent: "")
        let dirSub = NSMenu()
        func addDir(_ title: String, _ path: String?, checked: Bool) {
            let item = NSMenuItem(title: title, action: #selector(selectWorkDir(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path ?? ""
            item.state = checked ? .on : .off
            dirSub.addItem(item)
        }
        addDir("Aucun (simple conversation)", nil, checked: chat.workDir == nil)
        for path in settings.recentDirs where FileManager.default.fileExists(atPath: path) {
            addDir("\(URL(fileURLWithPath: path).lastPathComponent)  —  \((path as NSString).abbreviatingWithTildeInPath)", path, checked: chat.workDir?.path == path)
        }
        dirSub.addItem(.separator())
        let choose = NSMenuItem(title: "Choisir un dossier…", action: #selector(chooseWorkDir), keyEquivalent: "")
        choose.target = self
        dirSub.addItem(choose)
        dirMenu.submenu = dirSub
        menu.addItem(dirMenu)

        let modelAgent = chat.agent == .claudeSession ? Agent.claude : chat.agent
        let current = settings.models[modelAgent.rawValue]
        let modelList = modelAgent == .claude ? Self.claudeModels : agyModels
        let modelName = modelList.first { $0.id == current }?.name ?? current ?? "par défaut"
        let modelMenu = NSMenuItem(title: "Modèle (\(modelAgent.displayName)) : \(modelName)", action: nil, keyEquivalent: "")
        let modelSub = NSMenu()
        for (id, name) in [("", "Par défaut")] + modelList.map({ ($0.id, $0.name) }) {
            let item = NSMenuItem(title: name, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [modelAgent.rawValue, id]
            item.state = id == (current ?? "") ? .on : .off
            modelSub.addItem(item)
        }
        modelMenu.submenu = modelSub
        menu.addItem(modelMenu)

        add("Parler…", #selector(talk))
        add("Ouvrir le chat", #selector(openChat))
        add("Arrêter la réponse", #selector(stopReply), enabled: chat.isBusy)
        add("Nouvelle conversation", #selector(resetChat))
        menu.addItem(.separator())
        add("Se promener sur l'écran", #selector(toggleWander), checked: brain.wander)

        add("Particules et effets", #selector(toggleParticles), checked: settings.particles)
        add("Bulle d'activité de l'agent", #selector(toggleActivity), checked: settings.activityBubble)
        add("Sons", #selector(toggleSounds), checked: settings.sounds)

        let sizeMenu = NSMenuItem(title: "Taille : \(PetSizing.label(for: settings.size))", action: nil, keyEquivalent: "")
        let sizeSub = NSMenu()
        for level in PetSizing.levels {
            let item = NSMenuItem(title: level.name, action: #selector(selectSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = level.value
            item.state = level.value == settings.size ? .on : .off
            sizeSub.addItem(item)
        }
        sizeMenu.submenu = sizeSub
        menu.addItem(sizeMenu)

        let characterMenu = NSMenuItem(title: "Personnage", action: nil, keyEquivalent: "")
        let characterSub = NSMenu()
        for c in characters {
            let item = NSMenuItem(title: "\(c.name)  (\(c.source))", action: #selector(selectCharacter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.id
            item.state = c.id == pack.id ? .on : .off
            characterSub.addItem(item)
        }
        characterMenu.submenu = characterSub
        menu.addItem(characterMenu)

        let demo = NSMenuItem(title: "Animations", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for name in pack.animations.keys.sorted() { add(name, #selector(playAnimation(_:)), to: sub) }
        demo.submenu = sub
        menu.addItem(demo)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func selectAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let agent = Agent(rawValue: raw) else { return }
        if chat.select(agent) { bubble.hide() } else { NSSound.beep() }   // pas de changement pendant une réponse
    }

    @objc private func selectLiveSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let session = liveSessions[id] else { return }
        if chat.attachLive(sessionID: session.id, cwd: session.cwd, label: session.name) { bubble.hide() } else { NSSound.beep() }
    }

    @objc private func selectWorkDir(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        applyWorkDir(path.isEmpty ? nil : path)
    }

    @objc private func chooseWorkDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Travailler ici"
        panel.message = "Dossier où l'agent travaille quand tu lui écris."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { applyWorkDir(url.path) }
    }

    private func applyWorkDir(_ path: String?) {
        guard chat.setWorkDir(path.map { URL(fileURLWithPath: $0) }) else { NSSound.beep(); return }   // pas de changement pendant une réponse
        settings.chooseWorkDir(path)
        settings.save(dataDir)
        bubble.hide()
    }

    static let claudeModels: [(id: String, name: String)] = [
        ("claude-fable-5-1", "Fable 5.1"), ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-haiku-5-5", "Haiku 5.5"),
    ]

    /// Modèles d'Antigravity, lus une fois avec `agy models` (le réglage déjà choisi reste listé en cas d'échec).
    private var agyModels: [(id: String, name: String)] {
        if let cached = agyModelCache { return cached }
        DispatchQueue.global().async { [weak self] in
            let found = Self.fetchAgyModels()
            DispatchQueue.main.async { self?.agyModelCache = found }
        }
        return settings.models["antigravity"].map { [($0, $0)] } ?? []
    }
    private static func fetchAgyModels() -> [(id: String, name: String)] {
        guard let url = AgyRunner().locate() else { return [] }
        let process = Process(), pipe = Pipe()
        process.executableURL = url
        process.arguments = ["models"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return cols.count == 2 ? (cols[0], cols[1]) : nil
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        settings.models[pair[0]] = pair[1].isEmpty ? nil : pair[1]
        chat.models = settings.models
        settings.save(dataDir)
    }

    @objc private func stopReply() { chat.cancel() }
    @objc private func talk() { bubble.showInput() }
    @objc private func openChat() { chatWindow.show() }
    @objc private func resetChat() { chat.reset(); bubble.hide() }

    @objc private func toggleParticles() {
        settings.particles.toggle()
        particles.enabled = settings.particles
        if !settings.particles { particles.clear() }
        settings.save(dataDir)
    }

    @objc private func toggleActivity() {
        settings.activityBubble.toggle()
        activity.enabled = settings.activityBubble
        settings.save(dataDir)
    }

    @objc private func toggleSounds() {
        settings.sounds.toggle()
        settings.save(dataDir)
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double, value != settings.size else { return }
        settings.size = value
        settings.save(dataDir)
        applySize()
    }

    @objc private func selectCharacter(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != pack.id,
              let info = characters.first(where: { $0.id == id }) else { return }
        do {
            let loaded = try Pack.load(from: info.directory)
            pack = loaded
            particles.clear()
            brain.replacePack(loaded, now: now)
            applySize()   // la hauteur de référence (stand_height) peut différer d'un personnage à l'autre
            settings.character = id
            settings.save(dataDir)
            dataDir.appendLog("personnage : \(id)")
        } catch {
            dataDir.appendLog("personnage « \(id) » illisible : \(error)")
            NSSound.beep()
        }
    }

    @objc private func toggleWander() {
        settings.wander.toggle()
        brain.wander = settings.wander
        settings.save(dataDir)
    }

    @objc private func playAnimation(_ sender: NSMenuItem) { brain.demo(sender.title, now: now) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
