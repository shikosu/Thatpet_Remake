import Foundation

/// Table « événement d'agent » → état du personnage → animation du pack.
enum AgentEvents {
    static let hookEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "SubagentStart", "SubagentStop", "Stop",
        "StopFailure", "PreCompact", "SessionEnd",
    ]

    static func state(for event: String) -> String? {
        switch event {
        case "SessionStart": return "idle"
        case "UserPromptSubmit", "PreInvocation": return "thinking"
        case "PreToolUse", "PostToolUse", "SubagentStop": return "working"
        case "PostToolUseFailure": return "toolfail"
        case "PermissionRequest", "Notification": return "attention"
        case "SubagentStart": return "helper"
        case "Stop": return "celebrating"
        case "StopFailure": return "error"
        case "PreCompact": return "compacting"
        case "SessionEnd": return "stop"
        default: return nil
        }
    }

    static func animation(for state: String) -> String {
        switch state {
        case "toolfail": return "oops"
        case "stop": return "idle"
        default: return state
        }
    }

    /// États qui restent affichés jusqu'au prochain événement ; les autres reviennent seuls à idle.
    static let transient: Set<String> = ["celebrating", "error", "toolfail"]
}

/// Message envoyé par `hook` à l'app.
struct AgentMessage: Codable {
    var provider: String
    var event: String
    var state: String
    var session: String
    var tool: String?
    /// Demande de permission : texte à montrer, socket où répondre, date limite (secondes epoch).
    var detail: String?
    /// Dossier de travail de la session (permet de la reprendre).
    var cwd: String?
    var reply: String?
    var expires: Double?
}
