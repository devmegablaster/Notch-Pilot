import Foundation

/// Auto-installs the Node.js hook script and wires it into
/// `~/.claude/settings.json` so Claude Code invokes it on `PermissionRequest`.
///
/// Idempotent: safe to call on every launch. Preserves any existing hooks
/// the user already has configured.
enum HookInstaller {

    static let hookScriptSource: String = #"""
#!/usr/bin/env node
// NotchPilot hook — bridges Claude Code hook events to a Unix socket so the
// notch UI can show/respond to them. Fire-and-forget for most events;
// blocking for PermissionRequest.
const net = require('net');
const path = require('path');
const os = require('os');

const SOCKET_PATH = path.join(os.homedir(), '.notch-pilot/pilot.sock');
const TIMEOUT_MS = 120000;

let inputData = '';
process.stdin.on('data', chunk => { inputData += chunk; });
process.stdin.on('end', () => {
    let hookInput;
    try {
        hookInput = JSON.parse(inputData);
    } catch (e) {
        // Malformed input — don't block Claude.
        process.exit(0);
    }

    const eventName = hookInput.hook_event_name || 'Unknown';

    if (eventName === 'PermissionRequest') {
        handleBlocking(hookInput);
    } else if (eventName === 'PreToolUse' || eventName === 'UserPromptSubmit') {
        // Fire-and-forget: ping the buddy so it can learn the current
        // permission_mode (which lives in hook inputs but NOT in the jsonl
        // between user prompts).
        sendFireAndForget(hookInput);
    } else {
        process.exit(0);
    }
});

function sendFireAndForget(hookInput) {
    try {
        const client = net.createConnection(SOCKET_PATH);
        client.on('connect', () => {
            const msg = JSON.stringify({
                event: 'ModeUpdate',
                cwd: hookInput.cwd,
                permission_mode: hookInput.permission_mode
                    || hookInput.permissionMode
                    || '',
                session_id: hookInput.session_id,
            }) + '\n';
            client.write(msg);
            client.end();
        });
        client.on('error', () => { process.exit(0); });
        setTimeout(() => {
            try { client.destroy(); } catch (e) {}
            process.exit(0);
        }, 250);
    } catch (e) {
        process.exit(0);
    }
}

function handleBlocking(hookInput) {
    const client = net.createConnection(SOCKET_PATH);
    let buffer = '';

    const timer = setTimeout(() => {
        try { client.destroy(); } catch (e) {}
        // Fall through to Claude's default permission handling.
        process.exit(0);
    }, TIMEOUT_MS);

    client.on('connect', () => {
        const msg = JSON.stringify({
            event: 'PermissionRequest',
            session_id: hookInput.session_id,
            cwd: hookInput.cwd,
            tool_name: hookInput.tool_name,
            tool_input: hookInput.tool_input,
            permission_mode: hookInput.permission_mode,
        }) + '\n';
        client.write(msg);
    });

    client.on('data', chunk => {
        buffer += chunk.toString('utf8');
        const nl = buffer.indexOf('\n');
        if (nl < 0) return;

        clearTimeout(timer);
        const line = buffer.slice(0, nl);
        client.end();

        let resp;
        try { resp = JSON.parse(line); } catch (e) { process.exit(0); }

        if (resp.behavior === 'allow') {
            process.stdout.write(JSON.stringify({
                hookSpecificOutput: {
                    hookEventName: 'PermissionRequest',
                    decision: { behavior: 'allow' },
                },
            }));
            process.exit(0);
        }

        if (resp.behavior === 'deny') {
            const message = resp.message || 'Denied via Notch Pilot';
            // Official PermissionRequest deny schema — keep it strict, any
            // extraneous top-level fields (legacy "decision": "block", etc)
            // invalidate the response and Claude Code falls through to the
            // default path, which for AskUserQuestion means the native TUI
            // runs and our message never reaches the model.
            process.stdout.write(JSON.stringify({
                hookSpecificOutput: {
                    hookEventName: 'PermissionRequest',
                    decision: { behavior: 'deny', message: message },
                },
            }));
            process.exit(0);
        }

        process.exit(0);
    });

    client.on('error', () => {
        // NotchPilot isn't running — fall back to default behavior.
        clearTimeout(timer);
        process.exit(0);
    });
}
"""#

    static func installIfNeeded() {
        let home = NSHomeDirectory()
        let installDir = "\(home)/.notch-pilot"
        let hookScriptPath = "\(installDir)/hook.js"
        let settingsPath = "\(home)/.claude/settings.json"

        try? FileManager.default.createDirectory(
            atPath: installDir,
            withIntermediateDirectories: true
        )

        // Write / refresh the hook script if its contents changed.
        let existing = try? String(contentsOfFile: hookScriptPath, encoding: .utf8)
        if existing != hookScriptSource {
            do {
                try hookScriptSource.write(
                    toFile: hookScriptPath,
                    atomically: true,
                    encoding: .utf8
                )
                chmod(hookScriptPath, 0o755)
                print("[NotchPilot] Installed hook at \(hookScriptPath)")
            } catch {
                print("[NotchPilot] Hook write failed: \(error)")
                return
            }
        }

        updateClaudeSettings(at: settingsPath, hookPath: hookScriptPath)
    }

    private static func updateClaudeSettings(at path: String, hookPath: String) {
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        let hookEntry: [String: Any] = [
            "type": "command",
            "command": hookPath,
        ]
        let matcherEntry: [String: Any] = [
            "matcher": "*",
            "hooks": [hookEntry],
        ]

        let events = ["PermissionRequest", "PreToolUse", "UserPromptSubmit"]
        var changed = false
        for event in events {
            var eventEntries = (hooks[event] as? [[String: Any]]) ?? []
            let alreadyInstalled = eventEntries.contains { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String) == hookPath }
            }
            if !alreadyInstalled {
                eventEntries.append(matcherEntry)
                hooks[event] = eventEntries
                changed = true
            }
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
            print("[NotchPilot] Registered PermissionRequest hook in \(path)")
        } catch {
            print("[NotchPilot] settings.json update failed: \(error)")
        }
    }
}
