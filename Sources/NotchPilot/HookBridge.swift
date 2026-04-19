import Foundation
import Combine

/// Bridges socket events from the Claude Code hook into SwiftUI state.
///
/// The only blocking event we currently handle is `PermissionRequest`.
/// When one arrives, we park a `PendingPermission` into `@Published` state
/// and hold the hook's socket connection open (via a retained `respond`
/// closure) until the user clicks allow or deny in the notch UI.
@MainActor
final class HookBridge: ObservableObject {
    /// FIFO queue of permission requests. The first entry is the one
    /// currently shown in the notch; the rest are waiting. New requests
    /// append to the end so parallel tool calls queue up instead of
    /// clobbering each other. The earlier logic dropped a silent deny on
    /// the previous pending whenever a new one arrived — that's what made
    /// multiple concurrent requests feel like only the latest one "won".
    @Published private(set) var pendingPermissions: [PendingPermission] = []

    /// The permission currently shown to the user — always the head of
    /// the queue. Exposed as a non-@Published computed so NotchContentView
    /// can keep reading `hookBridge.pendingPermission`; SwiftUI still
    /// reacts because `pendingPermissions` is published.
    var pendingPermission: PendingPermission? { pendingPermissions.first }

    /// Count of additional permissions waiting behind the shown one —
    /// drives the "1 of N" pill in the permission panel header.
    var queuedBehindCurrent: Int { max(0, pendingPermissions.count - 1) }

    /// Published so the expanded panel's "Always allowed" section can
    /// reactively re-render when the user adds or removes entries.
    @Published private(set) var alwaysAllowedTools: Set<String> = []
    /// Live permission mode per cwd, learned from PreToolUse /
    /// UserPromptSubmit hook pings. Fresher than the jsonl's nativeMode
    /// because the hook fires on every tool call and prompt — so mid-session
    /// Shift+Tab changes get picked up within a single tool invocation
    /// instead of waiting for the next user prompt to land in the jsonl.
    @Published private(set) var liveModes: [String: String] = [:]

    /// Maps session ID → the claude process PID, learned from hook events
    /// and from startup scanning. The hook process is a child of the shell,
    /// which is a child of claude. Walking the peer PID's parent chain
    /// finds the claude PID.
    @Published private(set) var sessionPIDs: [String: Int32] = [:]

    private let server = SocketServer()
    private let socketPath: String
    private let settingsPath: String

    init() {
        socketPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".notch-pilot/pilot.sock")
        settingsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/settings.json")
        loadAlwaysAllowed()
    }

    private func loadAlwaysAllowed() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = root["permissions"] as? [String: Any],
              let allow = permissions["allow"] as? [String]
        else { return }
        // Only the bare-name entries can be matched against tool_name. Skip
        // scoped rules like "Bash(npm install:*)" — Claude Code's normal
        // matcher handles those, we don't need to second-guess it.
        alwaysAllowedTools = Set(allow.filter { !$0.contains("(") })
    }

    func start() {
        server.onRequest = { [weak self] request, respond in
            // We hop to the main actor so published state is always mutated
            // from the expected context. Bind weak self to a local let
            // first so the concurrent Task closure isn't capturing a var.
            guard let self else { respond(nil); return }
            Task { @MainActor in
                self.handle(request: request, respond: respond)
            }
        }

        server.onClientDisconnect = { [weak self] payload in
            guard let self else { return }
            Task { @MainActor in
                self.handleHookDisconnect(payload: payload)
            }
        }

        do {
            try server.start(at: socketPath)
            print("[NotchPilot] Socket listening at \(socketPath)")
        } catch {
            print("[NotchPilot] Socket server failed to start: \(error)")
        }
    }

    // MARK: - Event dispatch

    private func handle(
        request: SocketServer.Request,
        respond: @escaping @Sendable (SocketServer.Response?) -> Void
    ) {
        let event = request.payload["event"] as? String ?? ""

        switch event {
        case "PermissionRequest":
            learnSessionPID(payload: request.payload, peerPID: request.peerPID)
            handlePermission(payload: request.payload, respond: respond)
        case "ModeUpdate":
            learnSessionPID(payload: request.payload, peerPID: request.peerPID)
            handleModeUpdate(payload: request.payload)
            respond(nil)
        default:
            respond(nil)
        }
    }

    /// Walk the hook process's parent chain to find the claude PID.
    /// Hook → shell → claude (the hook is this app's binary, spawned
    /// by Claude Code via the shell invocation in settings.json).
    private func learnSessionPID(payload: [String: Any], peerPID: Int32?) {
        guard let sessionID = payload["session_id"] as? String,
              !sessionID.isEmpty,
              let hookPID = peerPID
        else { return }

        var current = hookPID
        for _ in 0..<8 {
            guard let parent = ProcessLookup.parent(of: current), parent > 1 else { break }
            let name = (ProcessLookup.name(of: parent) ?? "").lowercased()
            if name.contains("claude") {
                sessionPIDs[sessionID] = parent
                return
            }
            // Also check exe path for version-named binaries
            if let path = ProcessLookup.path(of: parent)?.lowercased(),
               path.contains("/claude/versions/") || path.hasSuffix("/claude") {
                sessionPIDs[sessionID] = parent
                return
            }
            current = parent
        }
    }

    private func handleModeUpdate(payload: [String: Any]) {
        guard let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return }
        let rawMode = (payload["permission_mode"] as? String)
            ?? (payload["permissionMode"] as? String)
            ?? ""
        guard !rawMode.isEmpty else { return }
        if liveModes[cwd] != rawMode {
            liveModes[cwd] = rawMode
        }
    }

    private func handlePermission(
        payload: [String: Any],
        respond: @escaping @Sendable (SocketServer.Response?) -> Void
    ) {
        let toolName = payload["tool_name"] as? String ?? "Tool"
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let sessionID = payload["session_id"] as? String ?? ""
        let cwd = payload["cwd"] as? String ?? ""
        let projectName = cwd.isEmpty
            ? "unknown"
            : (cwd as NSString).lastPathComponent

        // Global always-allow list.
        if alwaysAllowedTools.contains(toolName) {
            respond(SocketServer.Response(payload: ["behavior": "allow"]))
            return
        }

        // Append to the queue. The current head stays shown until the
        // user resolves it — the new one just waits its turn.
        pendingPermissions.append(PendingPermission(
            id: UUID(),
            toolName: toolName,
            toolInput: toolInput,
            sessionID: sessionID,
            cwd: cwd,
            projectName: projectName,
            createdAt: Date(),
            respond: respond
        ))
    }

    /// The hook process died before we sent a response — the user
    /// answered the permission prompt directly in the terminal. Remove
    /// the matching pending permission so the notch clears it.
    private func handleHookDisconnect(payload: [String: Any]) {
        let sessionID = payload["session_id"] as? String ?? ""
        let toolName = payload["tool_name"] as? String ?? ""
        if let idx = pendingPermissions.firstIndex(where: {
            $0.sessionID == sessionID && $0.toolName == toolName
        }) {
            pendingPermissions.remove(at: idx)
        }
    }

    /// Called periodically (e.g. from the monitor's refresh cycle) with
    /// live session data. If a session has produced new jsonl activity
    /// after a pending permission was queued, the user must have answered
    /// in the terminal — dismiss the stale prompt.
    func dismissStalePermissions(sessions: [ClaudeSession]) {
        var dismissed: [UUID] = []
        for perm in pendingPermissions {
            // Match by cwd since session_id from the hook might not
            // match the jsonl-derived session id exactly.
            if let session = sessions.first(where: { $0.cwd == perm.cwd }) {
                // If the session's last activity is more than 2 seconds
                // after the permission was created, it moved on.
                if session.lastActivity.timeIntervalSince(perm.createdAt) > 2 {
                    dismissed.append(perm.id)
                }
            }
        }
        for id in dismissed {
            removeFromQueue(id: id)
        }
    }

    // MARK: - User actions

    func allow(_ permission: PendingPermission) {
        resolve(permission, behavior: "allow")
    }

    func deny(_ permission: PendingPermission) {
        resolve(permission, behavior: "deny")
    }

    /// AskUserQuestion is a tool Claude uses to ask the user multiple-choice
    /// questions. Claude Code's hook system has no "answer" path for it, but
    /// the PermissionRequest deny `message` field is surfaced to the model
    /// as tool feedback. So we deny the tool and phrase the message as a
    /// direct answer — the LLM reads it and continues as if the tool ran.
    func selectQuestionOption(_ permission: PendingPermission, option: AskOption) {
        let answer: String
        if let desc = option.description, !desc.isEmpty {
            answer = "\(option.label) — \(desc)"
        } else {
            answer = option.label
        }
        let message = "The user answered your AskUserQuestion via the Notch Pilot UI. Their answer: \"\(answer)\". Treat this as if the tool had returned this selection and continue."
        permission.respond(SocketServer.Response(payload: [
            "behavior": "deny",
            "message": message
        ]))
        removeFromQueue(id: permission.id)
    }

    /// Approve this request AND remember the tool so future requests for the
    /// same tool name auto-approve. Persists to `~/.claude/settings.json`
    /// (`permissions.allow`) and updates the in-memory mirror.
    func allowAlways(_ permission: PendingPermission) {
        alwaysAllowedTools.insert(permission.toolName)
        appendToSettingsAllow(toolName: permission.toolName)
        resolve(permission, behavior: "allow")
    }

    /// Remove a tool from the always-allow list. The user can invoke this
    /// from the allow-list manager in the expanded panel to undo a previous
    /// "Always Allow" click without editing settings.json by hand.
    func removeFromAlwaysAllow(_ toolName: String) {
        alwaysAllowedTools.remove(toolName)
        removeFromSettingsAllow(toolName: toolName)
    }

    private func resolve(_ permission: PendingPermission, behavior: String) {
        permission.respond(SocketServer.Response(payload: ["behavior": behavior]))
        removeFromQueue(id: permission.id)
    }

    /// Remove a permission from the queue regardless of position. If it's
    /// the head (the one currently shown), the next queued request
    /// automatically becomes the new head because SwiftUI re-reads
    /// `pendingPermission` as a computed on `pendingPermissions.first`.
    private func removeFromQueue(id: UUID) {
        if let idx = pendingPermissions.firstIndex(where: { $0.id == id }) {
            pendingPermissions.remove(at: idx)
        }
    }

    private func appendToSettingsAllow(toolName: String) {
        mutateSettings { settings in
            var permissions = (settings["permissions"] as? [String: Any]) ?? [:]
            var allow = (permissions["allow"] as? [String]) ?? []
            guard !allow.contains(toolName) else { return nil }
            allow.append(toolName)
            permissions["allow"] = allow
            settings["permissions"] = permissions
            return settings
        }
        print("[NotchPilot] Added \(toolName) to permissions.allow")
    }

    private func removeFromSettingsAllow(toolName: String) {
        mutateSettings { settings in
            guard var permissions = settings["permissions"] as? [String: Any],
                  var allow = permissions["allow"] as? [String],
                  allow.contains(toolName)
            else { return nil }
            allow.removeAll { $0 == toolName }
            permissions["allow"] = allow
            settings["permissions"] = permissions
            return settings
        }
        print("[NotchPilot] Removed \(toolName) from permissions.allow")
    }

    /// Load / mutate / save the settings.json atomically. The mutator can
    /// return `nil` to abort the write (no-op).
    private func mutateSettings(_ mutate: (inout [String: Any]) -> [String: Any]?) {
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        guard let updated = mutate(&settings) else { return }

        let dir = (settingsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        if let data = try? JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }
    }
}

struct AskOption: Identifiable, Hashable {
    let id: Int
    let label: String
    let description: String?
}

struct PendingPermission: Identifiable {
    let id: UUID
    let toolName: String
    let toolInput: [String: Any]
    let sessionID: String
    let cwd: String
    let projectName: String
    let createdAt: Date
    let respond: @Sendable (SocketServer.Response?) -> Void

    /// A short one-liner describing what the tool wants to do.
    var summaryText: String {
        if let cmd = toolInput["command"] as? String {
            return cmd
        }
        if let path = toolInput["file_path"] as? String {
            return path
        }
        if let url = toolInput["url"] as? String {
            return url
        }
        if let pattern = toolInput["pattern"] as? String {
            return pattern
        }
        if isAskUserQuestion {
            return question
        }
        return ""
    }

    // MARK: - AskUserQuestion support

    var isAskUserQuestion: Bool {
        toolName == "AskUserQuestion"
    }

    /// The first question dict — Claude Code's AskUserQuestion takes a
    /// `questions: [{question, header, options: [{label, description}]}]`
    /// array. We only surface the first one in the notch UI; if the model
    /// really wants to ask more, it will do so in follow-up turns.
    private var firstQuestion: [String: Any]? {
        if let arr = toolInput["questions"] as? [[String: Any]], let first = arr.first {
            return first
        }
        return nil
    }

    var question: String {
        if let q = firstQuestion {
            if let s = q["question"] as? String, !s.isEmpty { return s }
            if let s = q["header"] as? String, !s.isEmpty { return s }
            if let s = q["prompt"] as? String, !s.isEmpty { return s }
        }
        if let q = toolInput["question"] as? String { return q }
        if let q = toolInput["prompt"] as? String { return q }
        if let q = toolInput["header"] as? String { return q }
        return ""
    }

    var askOptions: [AskOption] {
        // Preferred: nested `questions[0].options`.
        if let q = firstQuestion, let opts = parseOptionList(q["options"]) {
            return opts
        }
        // Legacy / flat fallback: top-level `options`.
        if let opts = parseOptionList(toolInput["options"]) {
            return opts
        }
        return []
    }

    private func parseOptionList(_ raw: Any?) -> [AskOption]? {
        if let arr = raw as? [[String: Any]] {
            let parsed: [AskOption] = arr.enumerated().compactMap { (idx, dict) in
                let label = (dict["label"] as? String)
                    ?? (dict["value"] as? String)
                    ?? (dict["text"] as? String)
                    ?? ""
                guard !label.isEmpty else { return nil }
                let desc = (dict["description"] as? String)
                    ?? (dict["detail"] as? String)
                return AskOption(id: idx, label: label, description: desc)
            }
            return parsed.isEmpty ? nil : parsed
        }
        if let arr = raw as? [String] {
            let parsed = arr.enumerated().map { idx, s in
                AskOption(id: idx, label: s, description: nil)
            }
            return parsed.isEmpty ? nil : parsed
        }
        return nil
    }
}
