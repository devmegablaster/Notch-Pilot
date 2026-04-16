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
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenEndpoint = URL(string: "https://api.anthropic.com/v1/oauth/token")!

    /// In-memory cached token from a refresh — never written to keychain
    /// to avoid breaking Claude Code's ACL on the credential entry.
    private static var cachedToken: (token: String, expiresAt: Double)?

    /// Read credentials, refresh if expired, return access token.
    /// Refreshed tokens are kept in-memory only — the keychain is
    /// never modified so Claude Code's credential entry stays intact.
    static func accessToken() async -> String? {
        // Use in-memory cached token if still valid
        if let cached = cachedToken {
            let now = Date().timeIntervalSince1970
            if now < cached.expiresAt - 300 {
                return cached.token
            }
        }

        guard let creds = readCredentials() else { return nil }

        // Check if keychain token is still valid
        let expiresAt = creds.expiresAt / 1000 // ms → seconds
        let now = Date().timeIntervalSince1970
        if now < expiresAt - 300 {
            return creds.accessToken
        }

        // Token expired — refresh and cache in-memory only
        guard let refreshed = await refreshToken(creds.refreshToken) else {
            return nil
        }
        cachedToken = (refreshed.accessToken, refreshed.expiresAt / 1000)
        return refreshed.accessToken
    }

    private struct Credentials {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double // milliseconds since epoch
    }

    private static func readCredentials() -> Credentials? {
        let task = Process()
        task.launchPath = "/usr/bin/security"
        task.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-w",
        ]
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
              let refresh = oauth["refreshToken"] as? String,
              let expires = oauth["expiresAt"] as? Double
        else { return nil }

        return Credentials(
            accessToken: token,
            refreshToken: refresh,
            expiresAt: expires
        )
    }

    private static func refreshToken(_ refreshToken: String) async -> Credentials? {
        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(clientID)"
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200
            else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccess = json["access_token"] as? String,
                  let newRefresh = json["refresh_token"] as? String,
                  let expiresIn = json["expires_in"] as? Double
            else { return nil }

            let newExpiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000

            return Credentials(
                accessToken: newAccess,
                refreshToken: newRefresh,
                expiresAt: newExpiresAt
            )
        } catch {
            return nil
        }
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
