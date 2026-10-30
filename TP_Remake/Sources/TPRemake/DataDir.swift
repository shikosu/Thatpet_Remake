import Foundation

/// Dossier de données : $TPREMAKE_DATA_DIR, sinon ~/Library/Application Support/TPRemake.
struct DataDir {
    let root: URL

    static func resolve() -> DataDir {
        if let env = ProcessInfo.processInfo.environment["TPREMAKE_DATA_DIR"], !env.isEmpty {
            return DataDir(root: URL(fileURLWithPath: env))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DataDir(root: base.appendingPathComponent("TPRemake"))
    }

    var run: URL { root.appendingPathComponent("run") }
    var socket: URL { run.appendingPathComponent("pet.sock") }
    var lock: URL { run.appendingPathComponent("pet.pid") }
    var state: URL { run.appendingPathComponent("state") }
    var log: URL { root.appendingPathComponent("log.txt") }

    func prepare() {
        try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    }

    /// Copie du binaire à un chemin stable : les hooks ne doivent pas casser après un `swift package clean`.
    var installedBinary: URL { root.appendingPathComponent("bin/TPRemake") }

    /// Installe (ou met à jour) la copie stable et renvoie son chemin.
    func installBinary(from source: String) throws -> String {
        let target = installedBinary
        let manager = FileManager.default
        if URL(fileURLWithPath: source).standardizedFileURL.path == target.standardizedFileURL.path { return target.path }
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent("TPRemake.new")
        try? manager.removeItem(at: temporary)
        try manager.copyItem(at: URL(fileURLWithPath: source), to: temporary)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        _ = try manager.replaceItemAt(target, withItemAt: temporary)
        return target.path
    }

    /// Taille au-delà de laquelle le journal passe dans log.old.txt.
    static let maxLogSize = 512 * 1024

    /// Ajoute une ligne au journal : écriture en une seule opération O_APPEND (sûre entre l'app et les hooks), avec rotation.
    func appendLog(_ line: String) {
        prepare()
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? Int, size > DataDir.maxLogSize {
            let old = root.appendingPathComponent("log.old.txt")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: log, to: old)
        }
        let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }
}
