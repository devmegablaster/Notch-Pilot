import Foundation
import Combine

enum ToolAction: String, Equatable {
    case none
    case reading    // Read, Grep, Glob, LS, NotebookRead
    case editing    // Edit, MultiEdit, Write, NotebookEdit
    case shell      // Bash (non-dangerous)
    case danger     // Bash with dangerous patterns (rm -rf, sudo rm, etc.)
    case thinking
    case web        // WebFetch, WebSearch
    case delegating // Task
    case planning   // TodoWrite
}

struct ClaudeSession: Identifiable, Equatable {
    let id: String
    let projectName: String
    let projectPath: String
    let cwd: String
    let startTime: Date
    let lastActivity: Date
    let lastMessage: String
    let shortStatus: String
    let model: String
    let nativeMode: String   // Claude Code's own permission mode (from jsonl)
    let toolAction: ToolAction
    let isActive: Bool
}

@MainActor
final class ClaudeMonitor: ObservableObject {
    @Published var sessions: [ClaudeSession] = []
    @Published var processCount: Int = 0

    private var timer: Timer?
    private let activeThreshold: TimeInterval = 15
    // Sessions whose jsonl hasn't been touched in this long are hidden from
    // the list entirely — Claude Code never deletes its session files, so
    // without this filter we'd show months of historical projects.
    private let shownThreshold: TimeInterval = 15 * 60

    // mtime-keyed parse cache. When a jsonl's mtime hasn't changed since
    // the last poll we reuse the cached parse instead of re-reading.
    private var parseCache: [String: (mtime: Date, message: String, status: String, cwd: String, model: String, nativeMode: String, toolAction: ToolAction)] = [:]

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Rebind weak self to a local let before the Task so the
            // inner concurrent closure isn't capturing a `var`. Swift 6's
            // strict concurrency rejects the var capture across actors.
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let newSessions = loadSessions()
        if newSessions != sessions {
            sessions = newSessions
        }
        let newCount = countClaudeProcesses()
        if newCount != processCount {
            processCount = newCount
        }
    }

    private func loadSessions() -> [ClaudeSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")
        let fm = FileManager.default

        guard let projects = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // Ground truth: how many `claude` processes are currently running
        // in each cwd. mtime alone lies — a cleanly exited session leaves
        // a fresh timestamp on its last write and looks alive for up to
        // shownThreshold minutes after the process is gone. An empty map
        // means no live claude processes → no sessions.
        let liveCwdCounts = liveClaudeCwdCounts()

        let now = Date()
        var livePaths = Set<String>()

        // Collected candidate jsonls before we apply the per-cwd capacity
        // filter. Each tuple carries everything we need to emit a session.
        struct Candidate {
            let sessionID: String
            let projectName: String
            let projectPath: String
            let cwd: String          // normalized, used as the group key
            let startTime: Date
            let lastActivity: Date
            let parsed: (message: String, status: String, cwd: String, model: String, nativeMode: String, toolAction: ToolAction)
        }
        var candidates: [Candidate] = []

        for projectURL in projects {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            guard let files = try? fm.contentsOfDirectory(
                at: projectURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            let jsonl = files.filter { $0.pathExtension == "jsonl" }
            guard !jsonl.isEmpty else { continue }

            // Each jsonl is a candidate — two `claude` processes in the
            // same cwd share a project directory but write to different
            // session-ID jsonls.
            for jsonlURL in jsonl {
                guard let lastActivity = mtime(jsonlURL) else { continue }

                // Sanity bound on mtime — anything older than shownThreshold
                // definitely isn't a live session and we skip the parse to
                // save work. (The cwd-count filter below is the real gate.)
                if now.timeIntervalSince(lastActivity) > shownThreshold {
                    continue
                }

                livePaths.insert(jsonlURL.path)

                let parsed = parseLastEntryCached(jsonlURL, mtime: lastActivity)
                // If the jsonl has no cwd yet (brand-new session, first
                // line not yet flushed) we can't match it to a live process,
                // so skip it. It will appear on a subsequent tick.
                guard !parsed.cwd.isEmpty else { continue }

                let projectName = (parsed.cwd as NSString).lastPathComponent
                let startTime: Date = {
                    if let attrs = try? fm.attributesOfItem(atPath: jsonlURL.path),
                       let created = attrs[.creationDate] as? Date {
                        return created
                    }
                    return lastActivity
                }()
                let sessionID = jsonlURL.deletingPathExtension().lastPathComponent

                candidates.append(Candidate(
                    sessionID: sessionID,
                    projectName: projectName,
                    projectPath: projectURL.path,
                    cwd: ProcessLookup.normalize(parsed.cwd),
                    startTime: startTime,
                    lastActivity: lastActivity,
                    parsed: parsed
                ))
            }
        }

        // Apply the per-cwd capacity filter: keep at most N candidates per
        // cwd, where N is the live claude-process count in that cwd. Most
        // recently active wins within a group.
        var grouped: [String: [Candidate]] = [:]
        for c in candidates {
            grouped[c.cwd, default: []].append(c)
        }

        var result: [ClaudeSession] = []
        for (cwd, group) in grouped {
            let capacity = liveCwdCounts[cwd] ?? 0
            guard capacity > 0 else { continue }
            let sorted = group.sorted { $0.lastActivity > $1.lastActivity }
            for c in sorted.prefix(capacity) {
                let isActive = now.timeIntervalSince(c.lastActivity) < activeThreshold
                result.append(ClaudeSession(
                    id: c.sessionID,
                    projectName: c.projectName,
                    projectPath: c.projectPath,
                    cwd: c.parsed.cwd,
                    startTime: c.startTime,
                    lastActivity: c.lastActivity,
                    lastMessage: c.parsed.message,
                    shortStatus: c.parsed.status,
                    model: c.parsed.model,
                    nativeMode: c.parsed.nativeMode,
                    toolAction: c.parsed.toolAction,
                    isActive: isActive
                ))
            }
        }

        // Evict stale cache entries for files that no longer exist.
        parseCache = parseCache.filter { livePaths.contains($0.key) }

        return result.sorted { $0.lastActivity > $1.lastActivity }
    }

    private func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func decodeProjectName(_ encoded: String) -> String {
        let path = encoded.replacingOccurrences(of: "-", with: "/")
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? encoded : name
    }

    // MARK: - Parsing (with mtime cache)

    private func parseLastEntryCached(_ url: URL, mtime: Date) -> (message: String, status: String, cwd: String, model: String, nativeMode: String, toolAction: ToolAction) {
        if let cached = parseCache[url.path], cached.mtime == mtime {
            return (cached.message, cached.status, cached.cwd, cached.model, cached.nativeMode, cached.toolAction)
        }
        let parsed = parseLastEntry(url)
        parseCache[url.path] = (mtime, parsed.message, parsed.status, parsed.cwd, parsed.model, parsed.nativeMode, parsed.toolAction)
        return parsed
    }

    private func parseLastEntry(_ url: URL) -> (message: String, status: String, cwd: String, model: String, nativeMode: String, toolAction: ToolAction) {
        let tail = readTail(url, bytes: 64 * 1024)
        guard !tail.isEmpty else { return ("", "", "", "", "", .none) }

        let lines = tail.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)

        var foundCwd: String?
        var foundModel: String?
        var foundNativeMode: String?
        var foundResult: (message: String, status: String)?
        var foundAction: ToolAction = .none

        for line in lines.reversed().prefix(50) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if foundCwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                foundCwd = cwd
            }
            if foundModel == nil,
               let msg = obj["message"] as? [String: Any],
               let model = msg["model"] as? String,
               !model.isEmpty {
                foundModel = model
            }
            // permissionMode is a top-level field on user/assistant entries —
            // Claude Code writes whatever the current native mode is on each.
            if foundNativeMode == nil,
               let pm = obj["permissionMode"] as? String,
               !pm.isEmpty {
                foundNativeMode = pm
            }

            if foundResult != nil {
                if foundCwd != nil && foundModel != nil && foundNativeMode != nil { break }
                continue
            }

            let type = obj["type"] as? String ?? ""

            if type == "assistant" {
                if let msg = obj["message"] as? [String: Any],
                   let content = msg["content"] as? [[String: Any]] {
                    if let toolBlock = content.reversed().first(where: {
                        ($0["type"] as? String) == "tool_use"
                    }),
                       let name = toolBlock["name"] as? String {
                        foundResult = (summarize(toolBlock: toolBlock), shortStatus(forTool: name))
                        if foundAction == .none {
                            foundAction = classify(
                                tool: name,
                                input: toolBlock["input"] as? [String: Any] ?? [:]
                            )
                        }
                        if foundCwd != nil && foundModel != nil && foundNativeMode != nil { break } else { continue }
                    }
                    if let lastBlock = content.last {
                        let blockType = lastBlock["type"] as? String ?? ""
                        if blockType == "thinking" {
                            foundResult = ("", "thinking")
                            if foundCwd != nil && foundModel != nil && foundNativeMode != nil { break } else { continue }
                        }
                        if blockType == "text", let text = lastBlock["text"] as? String {
                            foundResult = (String(text.prefix(180)), "")
                            if foundCwd != nil && foundModel != nil && foundNativeMode != nil { break } else { continue }
                        }
                    }
                }
                foundResult = ("", "")
                if foundCwd != nil && foundModel != nil && foundNativeMode != nil { break } else { continue }
            }

            if type == "user" {
                let preview: String
                if let msg = obj["message"] as? [String: Any] {
                    if let text = msg["content"] as? String {
                        preview = String(text.prefix(180))
                    } else if let blocks = msg["content"] as? [[String: Any]],
                              let first = blocks.first(where: { ($0["type"] as? String) == "text" }),
                              let text = first["text"] as? String {
                        preview = String(text.prefix(180))
                    } else {
                        preview = ""
                    }
                } else {
                    preview = ""
                }
                foundResult = (preview, "thinking")
                if foundCwd != nil && foundModel != nil && foundNativeMode != nil { break } else { continue }
            }
        }

        let result = foundResult ?? ("", "")
        return (
            result.message,
            result.status,
            foundCwd ?? "",
            foundModel ?? "",
            foundNativeMode ?? "",
            foundAction
        )
    }

    /// Classify a tool_use block into a coarse action category for the
    /// buddy to react to.
    private func classify(tool: String, input: [String: Any]) -> ToolAction {
        let name = tool.lowercased()
        switch name {
        case "edit", "multiedit", "write", "notebookedit":
            return .editing
        case "read", "grep", "glob", "ls", "notebookread":
            return .reading
        case "bash":
            if let cmd = input["command"] as? String, Self.isDangerousShell(cmd) {
                return .danger
            }
            return .shell
        case "webfetch", "websearch":
            return .web
        case "task":
            return .delegating
        case "todowrite":
            return .planning
        default:
            return .none
        }
    }

    /// Unambiguous danger keywords — any command containing one of these
    /// gets flagged. These all have no reasonable non-destructive use case.
    private static let dangerKeywords: [String] = [
        "drop table", "drop database",
        "dd if=/dev/random", "dd if=/dev/zero", "dd if=/dev/urandom",
        "mkfs.", "fdisk ",
        "chmod -r 777 /",
        ":(){ :|:& };:",        // fork bomb
        "git clean -fdx",        // wipes gitignored files too
    ]

    /// `rm -rf` / `rm -fr` is only flagged when the target is an absolute
    /// system path or a bare `/` / `~`. Routine cleanup like
    /// `rm -rf .build`, `rm -rf node_modules`, `rm -rf dist` is NOT flagged.
    private static let dangerRmTargets: [String] = [
        "rm -rf /", "rm -fr /",
        "rm -rf ~", "rm -fr ~",
        "rm -rf $home", "rm -fr $home",
    ]

    private static func isDangerousShell(_ raw: String) -> Bool {
        let s = raw.lowercased()

        if Self.dangerKeywords.contains(where: { s.contains($0) }) { return true }

        // Sudo + rm -rf is always scary regardless of target.
        if s.contains("sudo rm -rf") || s.contains("sudo rm -fr") { return true }

        // `rm -rf /` / `rm -rf ~` — but only when the `/` or `~` is the
        // actual target, not a prefix of a longer path like `/Users/foo`.
        // We check that the character immediately after the target is
        // whitespace, EOS, or a shell separator.
        for target in Self.dangerRmTargets {
            guard let range = s.range(of: target) else { continue }
            let after = range.upperBound
            if after == s.endIndex { return true }
            let next = s[after]
            if next == " " || next == "\n" || next == "\t" ||
               next == ";" || next == "|" || next == "&" {
                return true
            }
        }

        return false
    }

    private func readTail(_ url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func shortStatus(forTool name: String) -> String {
        switch name.lowercased() {
        case "bash": return "running shell"
        case "edit", "multiedit": return "editing"
        case "write": return "writing file"
        case "read": return "reading"
        case "glob": return "globbing"
        case "grep": return "searching"
        case "webfetch": return "fetching web"
        case "websearch": return "web search"
        case "task": return "delegating"
        case "todowrite": return "planning"
        case "notebookedit": return "notebook"
        default:
            return String(name.lowercased().prefix(14))
        }
    }

    private func summarize(toolBlock block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "tool"
        if let input = block["input"] as? [String: Any] {
            if let cmd = input["command"] as? String {
                return "\(name): \(String(cmd.prefix(120)))"
            }
            if let path = input["file_path"] as? String {
                return "\(name): \(path)"
            }
            if let pattern = input["pattern"] as? String {
                return "\(name): \(pattern)"
            }
        }
        return "→ \(name)"
    }

    /// Counts currently-running `claude` processes grouped by their working
    /// directory. A session's jsonl is only considered live if there is at
    /// least one claude PID with a matching cwd — and if multiple sessions
    /// share a cwd we keep at most `count` of them (the most recent ones).
    ///
    /// This is the ground truth: jsonl mtime alone lies because a cleanly
    /// exited session leaves a fresh last-write timestamp. lsof can't help
    /// either — claude closes the jsonl between writes — but the process's
    /// cwd fd IS held open for the life of the process, which is what we
    /// read via `proc_pidinfo`.
    private func liveClaudeCwdCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for pid in ProcessLookup.allPIDs() where pid > 0 {
            // Match on comm name OR exe path — `proc_name` usually reports
            // "claude", but the binary lives under `.local/share/claude/
            // versions/<ver>/...` and some codepaths report the version
            // folder instead. Check both so we don't miss either form.
            let name = ProcessLookup.name(of: pid) ?? ""
            let nameMatches = name.lowercased() == "claude"
            var pathMatches = false
            if !nameMatches {
                if let exePath = ProcessLookup.path(of: pid)?.lowercased() {
                    pathMatches = exePath.contains("/claude/versions/")
                        || exePath.hasSuffix("/claude")
                        || exePath.hasSuffix("/bin/claude")
                }
            }
            guard nameMatches || pathMatches else { continue }

            guard let cwd = ProcessLookup.cwd(of: pid), !cwd.isEmpty else { continue }
            counts[ProcessLookup.normalize(cwd), default: 0] += 1
        }
        if ProcessInfo.processInfo.environment["NOTCH_PILOT_DEBUG"] != nil {
            print("[NotchPilot] liveClaudeCwdCounts: \(counts)")
        }
        return counts
    }

    private func countClaudeProcesses() -> Int {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-fl", "claude"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return 0
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return 0 }

        return text.split(whereSeparator: \.isNewline).filter { line in
            let s = String(line).lowercased()
            guard !s.contains("notch") else { return false }
            return s.contains("claude")
        }.count
    }

    // MARK: - Session detail timeline

    /// Loads a chronological tail of events from a given session's jsonl.
    /// Used by the session-detail overlay. Returns oldest → newest.
    func recentEvents(for session: ClaudeSession, limit: Int = 30) -> [SessionEvent] {
        let url = URL(fileURLWithPath: session.projectPath)
            .appendingPathComponent("\(session.id).jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        // Read a generous tail — 256KB is enough for 30+ entries on
        // typical sessions and still cheap.
        let tail = readTail(url, bytes: 256 * 1024)
        guard !tail.isEmpty else { return [] }

        let lines = tail.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        var events: [SessionEvent] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String ?? ""
            let tsString = obj["timestamp"] as? String ?? ""
            let ts = Self.parseTimestamp(tsString) ?? Date()

            switch type {
            case "user":
                if let msg = obj["message"] as? [String: Any] {
                    // Tool result arrives as a user-typed entry with a
                    // tool_result content block — don't mistake for a
                    // real user prompt.
                    if let blocks = msg["content"] as? [[String: Any]],
                       let block = blocks.first(where: { ($0["type"] as? String) == "tool_result" }) {
                        let isError = (block["is_error"] as? Bool) ?? false
                        let body = Self.toolResultText(from: block)
                        events.append(SessionEvent(
                            kind: .toolResult,
                            timestamp: ts,
                            label: isError ? "Error" : "Result",
                            body: body,
                            icon: isError ? "exclamationmark.triangle" : "checkmark.circle",
                            isError: isError
                        ))
                    } else if let text = msg["content"] as? String, !text.isEmpty {
                        events.append(SessionEvent(
                            kind: .user,
                            timestamp: ts,
                            label: "You",
                            body: String(text.prefix(400)),
                            icon: "person.fill",
                            isError: false
                        ))
                    } else if let blocks = msg["content"] as? [[String: Any]],
                              let first = blocks.first(where: { ($0["type"] as? String) == "text" }),
                              let text = first["text"] as? String {
                        events.append(SessionEvent(
                            kind: .user,
                            timestamp: ts,
                            label: "You",
                            body: String(text.prefix(400)),
                            icon: "person.fill",
                            isError: false
                        ))
                    }
                }

            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let content = msg["content"] as? [[String: Any]]
                else { continue }

                for block in content {
                    let bt = block["type"] as? String ?? ""
                    switch bt {
                    case "tool_use":
                        let name = block["name"] as? String ?? "Tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        events.append(SessionEvent(
                            kind: .toolUse,
                            timestamp: ts,
                            label: name,
                            body: Self.toolUseSummary(name: name, input: input),
                            icon: Self.toolIcon(for: name),
                            isError: false
                        ))
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty {
                            events.append(SessionEvent(
                                kind: .assistantText,
                                timestamp: ts,
                                label: "Claude",
                                body: String(text.prefix(400)),
                                icon: "sparkles",
                                isError: false
                            ))
                        }
                    case "thinking":
                        events.append(SessionEvent(
                            kind: .thinking,
                            timestamp: ts,
                            label: "Thinking",
                            body: "",
                            icon: "brain",
                            isError: false
                        ))
                    default:
                        continue
                    }
                }

            default:
                continue
            }
        }

        // Newest last. Trim to the limit.
        if events.count > limit {
            return Array(events.suffix(limit))
        }
        return events
    }

    private static func toolResultText(from block: [String: Any]) -> String {
        if let s = block["content"] as? String {
            return String(s.prefix(300))
        }
        if let arr = block["content"] as? [[String: Any]] {
            let combined = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return String(combined.prefix(300))
        }
        return ""
    }

    private static func toolUseSummary(name: String, input: [String: Any]) -> String {
        if let cmd = input["command"] as? String { return String(cmd.prefix(220)) }
        if let path = input["file_path"] as? String {
            return (path as NSString).lastPathComponent
        }
        if let pattern = input["pattern"] as? String { return pattern }
        if let url = input["url"] as? String { return url }
        if let query = input["query"] as? String { return query }
        if let questions = input["questions"] as? [[String: Any]],
           let first = questions.first,
           let q = first["question"] as? String {
            return String(q.prefix(220))
        }
        return ""
    }

    private static func toolIcon(for name: String) -> String {
        switch name.lowercased() {
        case "bash", "bashoutput", "killshell": return "terminal"
        case "read", "notebookread":            return "doc.text"
        case "write":                            return "doc.badge.plus"
        case "edit", "multiedit", "notebookedit": return "pencil.and.outline"
        case "grep":                             return "magnifyingglass"
        case "glob", "ls":                       return "folder"
        case "webfetch":                         return "arrow.down.circle"
        case "websearch":                        return "globe"
        case "task":                             return "square.stack.3d.up"
        case "todowrite":                        return "checklist"
        case "askuserquestion":                  return "questionmark.bubble"
        default:                                 return "wrench.and.screwdriver"
        }
    }

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let timestampFormatterPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ s: String) -> Date? {
        timestampFormatter.date(from: s) ?? timestampFormatterPlain.date(from: s)
    }
}

/// One entry in a session's timeline as shown in the session-detail overlay.
struct SessionEvent: Identifiable {
    enum Kind {
        case user
        case assistantText
        case toolUse
        case thinking
        case toolResult
    }

    let id = UUID()
    let kind: Kind
    let timestamp: Date
    let label: String
    let body: String
    let icon: String
    let isError: Bool
}
