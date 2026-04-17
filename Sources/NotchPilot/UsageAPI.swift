import Foundation

/// Live usage percentages pulled from Anthropic's oauth/usage endpoint
/// — the same data Claude's account settings page shows you.
///
/// Each window carries a 0-100 utilization percentage and an optional
/// reset timestamp. Nil windows mean "not applicable for this plan"
/// (e.g. `sevenDayOpus` is null for plans without Opus access).
struct ClaudeUsage: Equatable {
    struct Window: Equatable {
        let utilization: Double    // 0…100
        let resetsAt: Date?
    }

    struct ExtraUsage: Equatable {
        let isEnabled: Bool
        let monthlyLimit: Int
        let usedCredits: Double
        let utilization: Double
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDaySonnet: Window?
    let sevenDayOpus: Window?
    let extraUsage: ExtraUsage?
    let fetchedAt: Date
}

/// Wraps the Anthropic API calls + Keychain credential read. All of
/// this is best-effort — on any failure we return nil and callers
/// fall back to local jsonl-derived data.
enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Read the Claude Code OAuth access token from the macOS Keychain
    /// by shelling out to `/usr/bin/security find-generic-password`.
    ///
    /// Why not `SecItemCopyMatching`? The "Claude Code-credentials"
    /// Keychain item has an ACL that's whitelisted to trusted binaries.
    /// When Claude Code originally writes the token it uses the
    /// `security` CLI, so `/usr/bin/security` ends up on the ACL
    /// automatically. Any later read via that same binary succeeds
    /// silently. A Swift `SecItemCopyMatching` call from our own app
    /// hits a different identity and prompts the user for their login
    /// keychain password — which is terrible UX and the reason Vibe
    /// Island also uses this exact exec path.
    /// Read the access token from the keychain. Never refreshes —
    /// Claude Code handles its own token refresh and writes fresh
    /// tokens to the keychain. We just read whatever's there.
    /// If the token is expired and Claude Code hasn't refreshed it,
    /// we return nil and the UI falls back to jsonl-derived data.
    static func accessToken() async -> String? {
        guard let creds = readCredentials() else { return nil }

        let expiresAt = creds.expiresAt / 1000
        let now = Date().timeIntervalSince1970
        if now < expiresAt {
            return creds.accessToken
        }

        // Expired — return nil, UI will show fallback
        return nil
    }

    private struct Credentials {
        let accessToken: String
        let expiresAt: Double // milliseconds since epoch
    }

    private static func readCredentials() -> Credentials? {
        // Try with the user's account name first (Claude Code writes
        // here after token refresh), then fall back to the null-account
        // entry (initial login). The account-specific entry has the
        // freshest tokens.
        if let creds = readKeychainEntry(account: NSUserName()) {
            return creds
        }
        return readKeychainEntry(account: nil)
    }

    private static func readKeychainEntry(account: String?) -> Credentials? {
        let task = Process()
        task.launchPath = "/usr/bin/security"
        var args = ["find-generic-password", "-s", "Claude Code-credentials"]
        if let acct = account {
            args += ["-a", acct]
        }
        args.append("-w")
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
        guard task.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              let expires = oauth["expiresAt"] as? Double
        else { return nil }

        return Credentials(
            accessToken: token,
            expiresAt: expires
        )
    }

    /// Hit the usage endpoint with the OAuth token. Returns nil if
    /// the token is missing / expired / the request fails.
    static func fetchUsage() async -> ClaudeUsage? {
        guard let token = await accessToken() else { return nil }

        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200
            else { return nil }
            return parse(data)
        } catch {
            return nil
        }
    }

    private static func parse(_ data: Data) -> ClaudeUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func window(_ key: String) -> ClaudeUsage.Window? {
            guard let dict = obj[key] as? [String: Any],
                  let util = dict["utilization"] as? Double
            else { return nil }
            let reset = (dict["resets_at"] as? String).flatMap(parseTimestamp)
            return ClaudeUsage.Window(utilization: util, resetsAt: reset)
        }

        var extra: ClaudeUsage.ExtraUsage? = nil
        if let ex = obj["extra_usage"] as? [String: Any],
           let enabled = ex["is_enabled"] as? Bool {
            extra = ClaudeUsage.ExtraUsage(
                isEnabled: enabled,
                monthlyLimit: (ex["monthly_limit"] as? Int) ?? 0,
                usedCredits: (ex["used_credits"] as? Double) ?? 0,
                utilization: (ex["utilization"] as? Double) ?? 0
            )
        }

        return ClaudeUsage(
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            sevenDaySonnet: window("seven_day_sonnet"),
            sevenDayOpus: window("seven_day_opus"),
            extraUsage: extra,
            fetchedAt: Date()
        )
    }

    /// ISO8601 with fractional seconds + timezone offset, matching
    /// the `resets_at` shape Anthropic returns
    /// (e.g. `2026-04-16T01:00:00.038614+00:00`).
    private static func parseTimestamp(_ s: String) -> Date? {
        if let d = formatterFractional.date(from: s) { return d }
        return formatterPlain.date(from: s)
    }

    nonisolated(unsafe) private static let formatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let formatterPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
