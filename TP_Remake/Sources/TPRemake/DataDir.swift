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

    func appendLog(_ line: String) {
        prepare()
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }
}
