import XCTest
@testable import TPRemake

/// Agent factice : un script shell qui imprime des lignes JSON puis dort.
private final class ScriptRunner: CLIRunner {
    let script: String
    var lines: [String] = []
    init(script: String) { self.script = script }
    override func locate() -> URL? { URL(fileURLWithPath: "/bin/sh") }
    override func arguments(prompt: String, sessionID: String?) -> [String] { ["-c", script] }
    override func handle(_ object: [String: Any]) { if let text = object["text"] as? String { lines.append(text) } }
}

final class CLIRunnerTests: XCTestCase {
    private func run(_ runner: CLIRunner, timeout: TimeInterval = 10, during: (() -> Void)? = nil) -> (text: String, isError: Bool)? {
        let done = expectation(description: "finished")
        var result: (String, Bool)?
        runner.onEvent = { if case .finished(let text, let isError) = $0 { result = (text, isError); done.fulfill() } }
        runner.send(prompt: "", sessionID: nil, workingDirectory: FileManager.default.temporaryDirectory)
        during?()
        wait(for: [done], timeout: timeout)
        return result
    }

    func testLastLineIsNotLostOnFastExit() {
        let runner = ScriptRunner(script: #"echo '{"text":"un"}'; echo '{"text":"deux"}'"#)
        _ = run(runner)
        XCTAssertEqual(runner.lines, ["un", "deux"])
    }

    func testCancelKillsGrandchildren() {
        let marker = "tpremake-test-\(UUID().uuidString)"
        let runner = ScriptRunner(script: "sleep 300 # \(marker)\n")
        let result = run(runner) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { runner.cancel() }
        }
        XCTAssertEqual(result?.text, "(interrompu)")
        Thread.sleep(forTimeInterval: 0.5)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-f", marker]
        check.standardOutput = FileHandle.nullDevice
        try? check.run(); check.waitUntilExit()
        XCTAssertNotEqual(check.terminationStatus, 0, "le petit-enfant `sleep` doit être arrêté")
    }
}

final class ClaudeRunnerStepTests: XCTestCase {
    func testToolUseBecomesStep() {
        let runner = ClaudeRunner()
        var steps: [String] = []
        runner.onEvent = { if case .step(let text) = $0 { steps.append(text) } }
        runner.handle(["type": "assistant", "message": ["content": [
            ["type": "text", "text": "ok"],
            ["type": "tool_use", "name": "Bash", "input": ["command": "npm test"]],
            ["type": "tool_use", "name": "Edit", "input": ["file_path": "/a/b.swift", "old_string": "x", "new_string": "y"]],
        ]]])
        XCTAssertEqual(steps, ["Bash : npm test", "Edit : /a/b.swift"])
    }
}
