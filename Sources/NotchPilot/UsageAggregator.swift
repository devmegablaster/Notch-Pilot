import Foundation
import Combine

/// Aggregates token usage + message counts from every Claude session
/// jsonl, bucketed into three rolling windows:
///
/// - **5h window**: messages sent in the last 5 hours. Maps to
///   Claude's per-session rate limit which resets every 5 hours.
/// - **today**: messages + tokens since the start of the current
///   calendar day.
/// - **week**: last 7 days.
///
/// The scan reads `message.usage` blocks from assistant entries —
/// that's where Claude Code records `input_tokens`, `output_tokens`,
/// `cache_read_input_tokens`, and `cache_creation_input_tokens`.
/// User entries don't carry usage data so they're skipped.
///
/// Cached for 60s per call to keep the cost bounded; the scan runs
/// on a background task.
@MainActor
final class UsageAggregator: ObservableObject {
    struct Window: Equatable {
        var messageCount: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreationTokens: Int = 0
        /// Earliest message timestamp falling inside this window.
        /// Used to compute when Anthropic's rolling window will
        /// "reset" (i.e., when that oldest message ages out).
        var earliestTimestamp: Date?

        /// Tokens actually billed (non-cache read) — input + output.
        var totalTokens: Int { inputTokens + outputTokens }
    }

    @Published private(set) var last5h: Window = Window()
    @Published private(set) var today: Window = Window()
    @Published private(set) var week: Window = Window()
    @Published private(set) var lastRefreshed: Date?

    /// Live usage percentages from Anthropic's oauth/usage endpoint.
    /// Nil when the user isn't signed into Claude Code or the request
    /// fails — callers should fall back to the jsonl-derived window
    /// counts in that case.
    @Published private(set) var live: ClaudeUsage?

    /// When the rolling 5h window will next drop its oldest message,
    /// computed as `earliestTimestamp + 5h`. Nil if no messages in the
    /// window. Use this for a "resets in 4h 28m" display.
    var fiveHourResetAt: Date? {
        last5h.earliestTimestamp.map { $0.addingTimeInterval(5 * 3600) }
    }

    /// Same for the 7-day rolling window.
    var weeklyResetAt: Date? {
        week.earliestTimestamp.map { $0.addingTimeInterval(7 * 24 * 3600) }
    }

    private let refreshInterval: TimeInterval = 60
    private var refreshTask: Task<Void, Never>?

    /// Kick off a refresh if the cache is stale. Safe to call
    /// repeatedly — coalesced internally. Does two things in
    /// parallel: a jsonl scan for the token breakdown, and a call
    /// to Anthropic's oauth/usage endpoint for the real percentages.
    func refreshIfNeeded() {
        if let last = lastRefreshed,
           Date().timeIntervalSince(last) < refreshInterval {
            return
        }
        if refreshTask != nil { return }

        refreshTask = Task { [weak self] in
            async let scanned = Task.detached(priority: .utility) {
                Self.scan()
            }.value
            async let fetched = UsageAPI.fetchUsage()

            let result = await scanned
            let liveUsage = await fetched

            await MainActor.run {
                guard let self = self else { return }
                self.last5h = result.last5h
                self.today = result.today
                self.week = result.week
                self.live = liveUsage
                self.lastRefreshed = Date()
                self.refreshTask = nil
            }
        }
    }

    // MARK: - Scan (runs off main)

    private nonisolated static func scan() -> (
        last5h: Window,
        today: Window,
        week: Window
    ) {
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)

        var last5h = Window()
        var today = Window()
        var week = Window()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")

        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (last5h, today, week)
        }

        for projectURL in projects {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDir),
                  isDir.boolValue
            else { continue }

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for fileURL in files where fileURL.pathExtension == "jsonl" {
                // Skip files last touched before the week cutoff —
                // they can't contribute to any window.
                let mtime = (try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                if mtime < weekAgo { continue }

                scan(
                    fileURL,
                    startOfToday: startOfToday,
                    fiveHoursAgo: fiveHoursAgo,
                    weekAgo: weekAgo,
                    last5h: &last5h,
                    today: &today,
                    week: &week
                )
            }
        }

        return (last5h, today, week)
    }

    private nonisolated static func scan(
        _ url: URL,
        startOfToday: Date,
        fiveHoursAgo: Date,
        weekAgo: Date,
        last5h: inout Window,
        today: inout Window,
        week: inout Window
    ) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }

        for rawLine in contents.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            // Fast reject — only lines with both a timestamp and a
            // usage block are worth parsing.
            guard line.contains("\"timestamp\":") && line.contains("\"usage\":") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tsString = obj["timestamp"] as? String,
                  let date = parseISO8601(tsString)
            else { continue }

            if date < weekAgo { continue }

            guard let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any]
            else { continue }

            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0

            func bump(_ w: inout Window) {
                w.messageCount += 1
                w.inputTokens += input
                w.outputTokens += output
                w.cacheReadTokens += cacheRead
                w.cacheCreationTokens += cacheCreate
                if w.earliestTimestamp == nil || date < (w.earliestTimestamp ?? date) {
                    w.earliestTimestamp = date
                }
            }

            bump(&week)
            if date >= startOfToday { bump(&today) }
            if date >= fiveHoursAgo { bump(&last5h) }
        }
    }

    /// Tolerant ISO8601 parser matching the one in HeatmapAggregator.
    private nonisolated static func parseISO8601(_ s: String) -> Date? {
        Self.isoFormatterFractional.date(from: s)
            ?? Self.isoFormatterPlain.date(from: s)
    }

    nonisolated(unsafe) private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoFormatterPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
