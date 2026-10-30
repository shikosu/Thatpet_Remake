import XCTest
@testable import TPRemake

final class ApprovalFilterTests: XCTestCase {
    func testHarmlessCommandsPass() {
        for command in ["ls -la", "git status", "git diff", "git log --oneline", "git branch", "git branch -a", "git remote -v", "rg foo", "cat README.md", "date"] {
            XCTAssertTrue(HookMode.isHarmless(command), command)
        }
    }

    func testDangerousCommandsNeedApproval() {
        let commands = [
            "rm -rf x", "git branch -D main", "git remote remove origin", "git diff --output=/tmp/x", "find . -fprint f",
            "find . -delete", "tree -o f", "rg --pre sh x", "cat ~/.ssh/id_rsa", "head ~/.aws/credentials", "cat .env",
            "date -s 2020", "ls; rm x", "ls | sh", "echo $(whoami)", "cat a > b",
        ]
        for command in commands { XCTAssertFalse(HookMode.isHarmless(command), command) }
    }

    func testReadOnlyToolsSkipApproval() {
        XCTAssertFalse(HookMode.needsApproval(tool: "Read", input: ["file_path": "/tmp/x"]))
        XCTAssertFalse(HookMode.needsApproval(tool: "view_file", input: [:]))
        XCTAssertTrue(HookMode.needsApproval(tool: "Write", input: ["file_path": "/tmp/x"]))
        XCTAssertTrue(HookMode.needsApproval(tool: "SomethingNew", input: [:]))
    }

    func testDescribeShowsEditDiffAndWorkingDirectory() {
        let text = HookMode.describe(tool: "Edit", input: ["file_path": "/a/b.txt", "old_string": "foo", "new_string": "bar"], cwd: "/proj")
        XCTAssertTrue(text.contains("/a/b.txt"))
        XCTAssertTrue(text.contains("- foo"))
        XCTAssertTrue(text.contains("+ bar"))
        XCTAssertTrue(text.contains("/proj"))
    }

    func testDescribeNeverTruncates() {
        let long = String(repeating: "a", count: 3000)
        XCTAssertEqual(HookMode.describe(tool: "Bash", input: ["command": long]), long)
    }
}
