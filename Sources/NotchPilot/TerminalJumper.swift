import Foundation
import AppKit

/// Finds the terminal application hosting a given Claude session and brings
/// it to the front.
///
/// Strategy:
/// 1. Enumerate all running processes via `ProcessLookup.allPIDs()`.
/// 2. Find the one whose command name contains "claude" AND whose current
///    working directory matches the session's project path.
/// 3. Walk its parent-process chain until we hit a process whose name
///    matches a known terminal emulator.
/// 4. Activate that `NSRunningApplication`.
///
/// This works even when Claude runs inside tmux — the parent chain is
/// `claude → shell → tmux → tmux-server → terminal`, and we skip past tmux
/// looking for a terminal app.
enum TerminalJumper {

    /// Known terminal emulators on macOS, matched by `proc_name`.
    private static let terminalExecutableNames: Set<String> = [
        "Terminal",
        "iTerm2", "iTerm",
        "Alacritty", "alacritty",
        "Ghostty", "ghostty",
        "kitty",
        "Warp", "stable",          // Warp reports as "stable"
        "WezTerm", "wezterm-gui",
        "Hyper",
        "Rio",
        "tabby",
    ]

    /// Known terminal bundle identifiers — used as a fallback when the
    /// parent-chain walk can't find a terminal (e.g. because Claude is
    /// running inside tmux, which detaches its server from the host
    /// terminal). In that case we can't identify *which* terminal has
    /// the tmux pane, so we just activate any running terminal app.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "org.alacritty",
        "io.alacritty",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.raphaelamorim.rio",
        "org.tabby",
    ]

    /// Jump to the terminal window hosting the claude process running
    /// with the given current working directory.
    ///
    /// Strategy (best → worst):
    /// 1. If claude is running inside tmux, navigate tmux to the exact
    ///    pane *before* activating the terminal app, so the user lands
    ///    on the right pane.
    /// 2. Walk claude's parent chain to find an ancestor terminal app
    ///    and activate it (works for direct-launch setups).
    /// 3. Fall back to activating any running terminal app by bundle
    ///    ID (covers tmux/screen + unusual launch chains).
    static func jump(toCwd cwd: String, claudePID knownPID: Int32? = nil, sessionID: String? = nil) {
        // Best: find the exact PID by checking which claude process has
        // the session's jsonl file open.
        var resolvedPID: Int32? = knownPID
        if resolvedPID == nil, let sid = sessionID, !sid.isEmpty {
            resolvedPID = findPIDBySessionID(sid, cwd: cwd)
        }

        let pidsToTry: [Int32]
        if let pid = resolvedPID {
            // Put the resolved PID first, then all others as fallback
            let all = findAllClaudePIDs(cwd: cwd)
            pidsToTry = [pid] + all.filter { $0 != pid }
        } else {
            pidsToTry = findAllClaudePIDs(cwd: cwd)
        }

        guard !pidsToTry.isEmpty else {
            print("[NotchPilot] No claude process with cwd \(cwd)")
            return
        }

        // Step 1: tmux pane navigation
        for pid in pidsToTry {
            if selectTmuxPane(forClaudePID: pid) {
                print("[NotchPilot] Switched tmux to pane for pid \(pid)")
                break
            }
        }

        // Step 2: parent-chain terminal activation.
        for pid in pidsToTry {
            if let terminalPID = findTerminalAncestor(startingAt: pid),
               let app = NSRunningApplication(processIdentifier: terminalPID) {
                app.activate()
                print("[NotchPilot] Activated \(app.localizedName ?? "terminal") (parent chain)")
                return
            }
        }

        // Step 3: fallback — any running terminal app.
        if let app = fallbackTerminalApp() {
            app.activate()
            print("[NotchPilot] Activated \(app.localizedName ?? "terminal") (bundle-ID fallback)")
            return
        }

        print("[NotchPilot] No terminal found for cwd \(cwd)")
    }

    /// Find the claude PID that has the session's jsonl file open.
    private static func findPIDBySessionID(_ sessionID: String, cwd: String) -> Int32? {
        // The jsonl lives at ~/.claude/projects/<encoded-cwd>/<sessionID>.jsonl
        // Find all claude PIDs for this cwd, then check which one's parent
        // shell PID matches a tmux pane. Actually simpler: check /proc-style
        // with lsof for which process has the jsonl open.
        let pids = findAllClaudePIDs(cwd: cwd)
        guard pids.count > 1 else { return pids.first }

        // Find the jsonl path for this session
        let home = NSHomeDirectory()
        let projectsDir = "\(home)/.claude/projects"
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else {
            return pids.first
        }

        var jsonlPath: String?
        for dir in projectDirs {
            let candidate = "\(projectsDir)/\(dir)/\(sessionID).jsonl"
            if fm.fileExists(atPath: candidate) {
                jsonlPath = candidate
                break
            }
        }

        guard let path = jsonlPath else { return pids.first }

        // lsof the specific file to find which PID has it open
        guard let result = runProcess("/usr/bin/lsof", ["-t", path]) else {
            return pids.first
        }

        for line in result.split(whereSeparator: \.isNewline) {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                if pids.contains(pid) {
                    return pid
                }
            }
        }

        return pids.first
    }

    /// Returns true if the user is currently looking at the tmux pane
    /// (or terminal window) running this specific claude session.
    /// Checks: (1) a terminal app is frontmost, (2) if tmux, the
    /// active pane in the active window is the one running this claude.
    static func isTerminalFocused(forCwd cwd: String, claudePID: Int32? = nil) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let frontBID = frontmost.bundleIdentifier,
              terminalBundleIDs.contains(frontBID)
        else { return false }

        let pid = claudePID ?? findClaudePID(cwd: cwd)
        guard let claudePID = pid else { return false }

        // Non-tmux: walk up to find the terminal ancestor
        if let termPID = findTerminalAncestor(startingAt: claudePID),
           let termApp = NSRunningApplication(processIdentifier: termPID) {
            return termApp.processIdentifier == frontmost.processIdentifier
        }

        // tmux: find which pane this claude is in, then check if that
        // pane is the currently active pane in the active window.
        guard let tmuxPath = findTmux() else { return false }

        var ancestors: Set<Int32> = []
        var current = claudePID
        for _ in 0..<16 {
            guard let parent = ProcessLookup.parent(of: current), parent > 1 else { break }
            ancestors.insert(parent)
            current = parent
        }

        // Find this claude's pane target
        guard let listing = runProcess(
            tmuxPath,
            ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{window_active}|#{pane_active}"]
        ) else { return false }

        for line in listing.split(whereSeparator: \.isNewline) {
            let parts = String(line).split(separator: "|")
            guard parts.count == 4,
                  let pid = Int32(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }

            if ancestors.contains(pid) {
                let windowActive = parts[2] == "1"
                let paneActive = parts[3] == "1"
                // This is claude's pane. Check if it's the active
                // pane in the active window AND the terminal is focused.
                return windowActive && paneActive
            }
        }

        return false
    }

    /// Check if `pid` is a descendant of `ancestor` by walking parent chain.
    private static func isDescendant(pid: Int32, of ancestor: Int32) -> Bool {
        var current = pid
        for _ in 0..<16 {
            if current == ancestor { return true }
            guard let parent = ProcessLookup.parent(of: current), parent > 1 else { return false }
            current = parent
        }
        return false
    }

    // MARK: - tmux pane navigation

    /// If tmux is installed and has a pane whose pid sits in claude's
    /// parent chain, select that pane (and its window). Returns true
    /// when a pane was selected. Silently no-ops otherwise.
    private static func selectTmuxPane(forClaudePID claudePID: Int32) -> Bool {
        guard let tmuxPath = findTmux() else { return false }

        // Collect claude's ancestor PIDs — every pane that hosts claude
        // will have its `pane_pid` (the shell) somewhere in this set.
        var ancestors: Set<Int32> = []
        var current = claudePID
        for _ in 0..<16 {
            guard let parent = ProcessLookup.parent(of: current), parent > 1 else { break }
            ancestors.insert(parent)
            current = parent
        }
        guard !ancestors.isEmpty else { return false }

        // Use | as separator since session names can contain spaces.
        guard let listing = runProcess(
            tmuxPath,
            ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}"]
        ) else { return false }

        var target: String?
        for line in listing.split(whereSeparator: \.isNewline) {
            guard let pipeIdx = line.lastIndex(of: "|") else { continue }
            let paneTarget = String(line[line.startIndex..<pipeIdx])
            let pidStr = String(line[line.index(after: pipeIdx)...])
            guard let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces))
            else { continue }
            if ancestors.contains(pid) {
                target = paneTarget
                break
            }
        }

        guard let t = target else { return false }

        // Extract the session name from "session:window.pane"
        let sessionName = t.split(separator: ":").first.map(String.init) ?? t

        // Switch the client to the target session (in case it's
        // attached to a different one), then select window + pane.
        _ = runProcess(tmuxPath, ["switch-client", "-t", sessionName])
        _ = runProcess(tmuxPath, ["select-window", "-t", t])
        _ = runProcess(tmuxPath, ["select-pane", "-t", t])
        return true
    }

    private static func findTmux() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",   // Apple Silicon Homebrew
            "/usr/local/bin/tmux",      // Intel Homebrew
            "/usr/bin/tmux",            // system (rare)
            "/run/current-system/sw/bin/tmux", // NixOS / nix-darwin
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        // Fallback: ask the shell
        guard let result = runProcess("/bin/sh", ["-l", "-c", "which tmux"]) else { return nil }
        let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func runProcess(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        // Inherit a useful PATH so tmux and other tools are findable
        // even when running from a sandboxed .app bundle.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin",
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        task.environment = env
        let out = Pipe()
        task.standardOutput = out
        let err = Pipe()
        task.standardError = err
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("[NotchPilot] runProcess failed: \(path) \(args) error: \(error)")
            return nil
        }
        if task.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            print("[NotchPilot] runProcess exit \(task.terminationStatus): \(path) \(args) stderr: \(errStr)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func fallbackTerminalApp() -> NSRunningApplication? {
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier else { continue }
            if terminalBundleIDs.contains(bid) {
                return app
            }
        }
        return nil
    }

    // MARK: - Process enumeration

    private static func findClaudePID(cwd: String) -> Int32? {
        findAllClaudePIDs(cwd: cwd).first
    }

    private static func findAllClaudePIDs(cwd: String) -> [Int32] {
        let targetCwd = ProcessLookup.normalize(cwd)
        var result: [Int32] = []

        for pid in ProcessLookup.allPIDs() where pid > 0 {
            let name = (ProcessLookup.name(of: pid) ?? "").lowercased()
            let nameMatches = name.contains("claude") || name == "node"
            var pathMatches = false
            if !nameMatches {
                if let exePath = ProcessLookup.path(of: pid)?.lowercased() {
                    pathMatches = exePath.contains("/claude/versions/")
                        || exePath.hasSuffix("/claude")
                        || exePath.hasSuffix("/bin/claude")
                }
            }
            guard nameMatches || pathMatches else { continue }

            guard let procCwd = ProcessLookup.cwd(of: pid) else { continue }
            if ProcessLookup.normalize(procCwd) == targetCwd {
                result.append(pid)
            }
        }
        return result
    }

    private static func findTerminalAncestor(startingAt pid: Int32) -> Int32? {
        var current = pid
        // Guard against cycles / runaway loops.
        for _ in 0..<12 {
            guard let parent = ProcessLookup.parent(of: current), parent > 1 else { return nil }
            if let name = ProcessLookup.name(of: parent) {
                if terminalExecutableNames.contains(name) {
                    return parent
                }
                if NSRunningApplication(processIdentifier: parent) != nil,
                   isTerminalLike(name: name) {
                    return parent
                }
            }
            current = parent
        }
        return nil
    }

    private static func isTerminalLike(name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("term") || lowered.contains("shell") || lowered == "warp"
    }
}
