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
    static func jump(toCwd cwd: String) {
        guard let claudePID = findClaudePID(cwd: cwd) else {
            print("[NotchPilot] No claude process with cwd \(cwd)")
            return
        }

        // Step 1: tmux pane navigation (best effort, no-op if not tmux).
        if selectTmuxPane(forClaudePID: claudePID) {
            print("[NotchPilot] Switched tmux to the pane running claude")
        }

        // Step 2: parent-chain terminal activation.
        if let terminalPID = findTerminalAncestor(startingAt: claudePID),
           let app = NSRunningApplication(processIdentifier: terminalPID) {
            app.activate()
            print("[NotchPilot] Activated \(app.localizedName ?? "terminal") (parent chain)")
            return
        }

        // Step 3: fallback — any running terminal app.
        if let app = fallbackTerminalApp() {
            app.activate()
            print("[NotchPilot] Activated \(app.localizedName ?? "terminal") (bundle-ID fallback)")
            return
        }

        print("[NotchPilot] No terminal ancestor for pid \(claudePID) and no terminal app running")
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

        // list-panes -a: every pane in every session on the default
        // socket. Format: "session:window.pane pid".
        guard let listing = runProcess(
            tmuxPath,
            ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_pid}"]
        ) else { return false }

        var target: String?
        for line in listing.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let pid = Int32(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            if ancestors.contains(pid) {
                target = String(parts[0])
                break
            }
        }

        guard let t = target else { return false }

        _ = runProcess(tmuxPath, ["select-window", "-t", t])
        _ = runProcess(tmuxPath, ["select-pane", "-t", t])
        return true
    }

    private static func findTmux() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",   // Apple Silicon Homebrew
            "/usr/local/bin/tmux",      // Intel Homebrew
            "/usr/bin/tmux",            // system (rare)
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    private static func runProcess(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
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
        // Normalize the target cwd once so /private prefixes and trailing
        // slashes don't cause false negatives when comparing.
        let targetCwd = ProcessLookup.normalize(cwd)

        for pid in ProcessLookup.allPIDs() where pid > 0 {
            // Match by comm name OR exe path — same dual-check as
            // ClaudeMonitor, because real claude processes sometimes
            // report a version string like "2.1.101" for proc_name
            // rather than "claude". Also still accept "node" in case
            // Claude was launched via an npm wrapper.
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
                return pid
            }
        }
        return nil
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
