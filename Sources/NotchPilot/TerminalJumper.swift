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
        "Alacritty",
        "Ghostty", "ghostty",
        "kitty",
        "Warp", "stable",          // Warp reports as "stable"
        "WezTerm", "wezterm-gui",
        "Hyper",
        "Rio",
        "tabby",
    ]

    /// Jump to the terminal window hosting the claude process running with
    /// the given current working directory.
    static func jump(toCwd cwd: String) {
        guard let claudePID = findClaudePID(cwd: cwd) else {
            print("[NotchPilot] No claude process with cwd \(cwd)")
            return
        }
        guard let terminalPID = findTerminalAncestor(startingAt: claudePID) else {
            print("[NotchPilot] No terminal ancestor for pid \(claudePID)")
            return
        }
        if let app = NSRunningApplication(processIdentifier: terminalPID) {
            app.activate()
            print("[NotchPilot] Activated \(app.localizedName ?? "terminal") for session at \(cwd)")
        }
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
