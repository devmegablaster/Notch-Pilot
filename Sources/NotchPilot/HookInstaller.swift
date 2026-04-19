import Foundation

/// Wires `~/.claude/settings.json` so Claude Code invokes THIS app binary
/// (with `--hook`) on permission / tool / prompt events. The hook logic
/// itself lives in `HookClient.swift` — same binary, different mode.
///
/// Idempotent: safe to call on every launch. Re-running picks up any
/// app-path changes (e.g. the user drags the app from Downloads into
/// Applications) and cleans up legacy `hook.js` entries from the old
/// Node-based implementation.
enum HookInstaller {

    /// Hook events we register for. Matcher is `"*"` for all.
    private static let events = ["PermissionRequest", "PreToolUse", "UserPromptSubmit"]

    /// Path to this running binary. Used as the hook command so Claude
    /// Code launches us with `--hook`. Falls back to argv[0] for SwiftPM
    /// dev builds where `Bundle.main.executablePath` may be unset.
    private static var executablePath: String {
        if let p = Bundle.main.executablePath, !p.isEmpty { return p }
        return CommandLine.arguments.first ?? ""
    }

    static func installIfNeeded() {
        let home = NSHomeDirectory()
        let installDir = "\(home)/.notch-pilot"
        let legacyScriptPath = "\(installDir)/hook.js"
        let settingsPath = "\(home)/.claude/settings.json"

        try? FileManager.default.createDirectory(
            atPath: installDir,
            withIntermediateDirectories: true
        )

        // Clean up the old Node-based hook script if it's still sitting
        // on disk from a previous install. Harmless if it's already gone.
        try? FileManager.default.removeItem(atPath: legacyScriptPath)

        updateClaudeSettings(at: settingsPath, legacyScriptPath: legacyScriptPath)
    }

    /// Build the shell command string Claude Code invokes. Claude Code
    /// runs hook commands via the shell, so space-separated args work —
    /// but we still quote the exe path in case it contains spaces (e.g.
    /// "/Applications/Notch Pilot.app/…").
    private static func hookCommand() -> String {
        let path = executablePath
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        return "\(quoted) --hook"
    }

    private static func updateClaudeSettings(at path: String, legacyScriptPath: String) {
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        let command = hookCommand()
        let hookEntry: [String: Any] = ["type": "command", "command": command]
        let matcherEntry: [String: Any] = ["matcher": "*", "hooks": [hookEntry]]

        var changed = false
        for event in events {
            var eventEntries = (hooks[event] as? [[String: Any]]) ?? []

            // Drop any entries that point to an obsolete NotchPilot hook:
            // either the legacy Node script or a previous app-binary path
            // that no longer matches the current one (e.g., user moved
            // the app bundle).
            let filtered = eventEntries.compactMap { entry -> [String: Any]? in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return entry }
                let kept = inner.filter { hook in
                    guard let cmd = hook["command"] as? String else { return true }
                    let isOursButStale =
                        cmd.contains(legacyScriptPath)
                        || (cmd.hasSuffix(" --hook") && cmd != command)
                    return !isOursButStale
                }
                if kept.count == inner.count { return entry }
                if kept.isEmpty { return nil }
                var updated = entry
                updated["hooks"] = kept
                return updated
            }
            if filtered.count != eventEntries.count
                || !zip(filtered, eventEntries).allSatisfy({ NSDictionary(dictionary: $0.0).isEqual(to: $0.1) }) {
                eventEntries = filtered
                changed = true
            }

            let alreadyInstalled = eventEntries.contains { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String) == command }
            }
            if !alreadyInstalled {
                eventEntries.append(matcherEntry)
                changed = true
            }

            hooks[event] = eventEntries
        }

        guard changed else { return }
        settings["hooks"] = hooks

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: URL(fileURLWithPath: path))
            print("[NotchPilot] Registered hook (\(command)) in \(path)")
        } catch {
            print("[NotchPilot] settings.json update failed: \(error)")
        }
    }
}
