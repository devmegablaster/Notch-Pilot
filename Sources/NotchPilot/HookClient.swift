import Foundation
import Darwin

/// Hook-mode entry point. When the main binary is invoked with `--hook`,
/// `main()` dispatches here instead of loading AppKit. This is what
/// Claude Code runs for each registered hook event; it's a tiny
/// stdio ↔ Unix-socket bridge to the main app's `SocketServer`.
///
/// Previously this lived in a bundled `hook.js` that required Node on the
/// user's PATH. Rewriting it in Swift and invoking the same app binary
/// eliminates the Node dependency entirely — Claude Code just runs the
/// app binary with an extra arg, and the hook logic is always in sync
/// with the installed app version.
enum HookClient {
    private static let socketPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(".notch-pilot/pilot.sock")
    /// Upper bound on how long we'll wait for the user to allow/deny a
    /// permission request. Matches the old hook.js value.
    private static let blockingTimeoutSeconds: Int = 120

    static func run() -> Never {
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        guard
            let obj = try? JSONSerialization.jsonObject(with: stdinData),
            let hookInput = obj as? [String: Any]
        else {
            // Malformed input — don't block Claude.
            exit(0)
        }

        let eventName = hookInput["hook_event_name"] as? String ?? "Unknown"

        switch eventName {
        case "PermissionRequest":
            handleBlocking(hookInput)
        case "PreToolUse", "UserPromptSubmit":
            // Fire-and-forget: let the app learn the current permission_mode
            // (which is in hook inputs but not in the jsonl between prompts).
            sendFireAndForget(hookInput)
        default:
            exit(0)
        }
    }

    // MARK: - Socket helpers

    /// Connect to the app's Unix socket. Returns -1 if the app isn't
    /// listening (fall through to Claude's default behavior).
    private static func connectSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cPath in
            let len = min(strlen(cPath), 103)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                _ = memcpy(raw.baseAddress, cPath, len)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, size)
            }
        }
        if result < 0 {
            close(fd)
            return -1
        }
        return fd
    }

    private static func writeLine(_ fd: Int32, _ dict: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: dict) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var remaining = raw.count
            var cursor = base
            while remaining > 0 {
                let n = write(fd, cursor, remaining)
                if n <= 0 { return false }
                remaining -= n
                cursor = cursor.advanced(by: n)
            }
            return true
        }
    }

    // MARK: - Event handlers

    private static func sendFireAndForget(_ hookInput: [String: Any]) -> Never {
        let fd = connectSocket()
        if fd < 0 { exit(0) }
        defer { close(fd) }

        let msg: [String: Any] = [
            "event": "ModeUpdate",
            "cwd": hookInput["cwd"] ?? "",
            "permission_mode":
                hookInput["permission_mode"]
                ?? hookInput["permissionMode"]
                ?? "",
            "session_id": hookInput["session_id"] ?? "",
        ]
        _ = writeLine(fd, msg)
        exit(0)
    }

    private static func handleBlocking(_ hookInput: [String: Any]) -> Never {
        let fd = connectSocket()
        if fd < 0 { exit(0) }
        defer { close(fd) }

        // Bound the wait on recv so a stuck app doesn't keep Claude blocked
        // forever. Matches hook.js's TIMEOUT_MS.
        var tv = timeval(tv_sec: blockingTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let request: [String: Any] = [
            "event": "PermissionRequest",
            "session_id": hookInput["session_id"] ?? "",
            "cwd": hookInput["cwd"] ?? "",
            "tool_name": hookInput["tool_name"] ?? "",
            "tool_input": hookInput["tool_input"] ?? [:],
            "permission_mode": hookInput["permission_mode"] ?? "",
        ]
        guard writeLine(fd, request) else { exit(0) }

        // Read until newline or timeout / disconnect.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var response: Data?
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { buf -> Int in
                read(fd, buf.baseAddress, buf.count)
            }
            if n <= 0 { exit(0) }
            buffer.append(chunk, count: n)
            if let nl = buffer.firstIndex(of: 0x0A) {
                response = buffer.subdata(in: 0..<nl)
                break
            }
        }

        guard
            let respData = response,
            let respObj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any]
        else {
            exit(0)
        }

        let behavior = respObj["behavior"] as? String ?? ""
        let message = (respObj["message"] as? String) ?? "Denied via Notch Pilot"

        // Output the official PermissionRequest decision schema. Keep it
        // strict — any extraneous top-level fields (e.g., "decision":
        // "block") cause Claude Code to treat the response as invalid and
        // fall through to the default TUI.
        let decision: [String: Any]
        switch behavior {
        case "allow":
            decision = ["behavior": "allow"]
        case "deny":
            decision = ["behavior": "deny", "message": message]
        default:
            exit(0)
        }
        let out: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: out) {
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    }
}
