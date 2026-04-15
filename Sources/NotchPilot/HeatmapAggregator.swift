import Foundation
import Combine

/// Aggregates today's Claude activity from every session jsonl in
/// `~/.claude/projects/`, binned by hour. Designed to be cheap to query
/// (cached for 60s) and safe to call from the main thread — the actual
/// scan runs on a background task.
@MainActor
final class HeatmapAggregator: ObservableObject {
    @Published private(set) var hourlyCounts: [Int] = Array(repeating: 0, count: 24)
    @Published private(set) var maxCount: Int = 0
    @Published private(set) var totalToday: Int = 0
    @Published private(set) var lastRefreshed: Date? = nil

    private let refreshInterval: TimeInterval = 60
    private var refreshTask: Task<Void, Never>?

    /// Kick off a refresh if the cached data is older than `refreshInterval`.
    /// Safe to call repeatedly — coalesced internally.
    func refreshIfNeeded() {
        if let last = lastRefreshed,
           Date().timeIntervalSince(last) < refreshInterval {
            return
        }
        if refreshTask != nil { return }

        refreshTask = Task { [weak self] in
            let counts = await Task.detached(priority: .utility) {
                Self.scanToday()
            }.value
            await MainActor.run {
                guard let self = self else { return }
                self.hourlyCounts = counts
                self.maxCount = counts.max() ?? 0
                self.totalToday = counts.reduce(0, +)
                self.lastRefreshed = Date()
                self.refreshTask = nil
            }
        }
    }

    // MARK: - Scan (runs off main)

    private nonisolated static func scanToday() -> [Int] {
        var counts = Array(repeating: 0, count: 24)
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")

        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return counts
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
                // Skip files whose mtime is before today — no contributions
                // possible, don't read them at all.
                let mtime = (try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                if mtime < startOfToday { continue }

                scan(fileURL, into: &counts, calendar: calendar, startOfToday: startOfToday)
            }
        }
        return counts
    }

    private nonisolated static func scan(
        _ url: URL,
        into counts: inout [Int],
        calendar: Calendar,
        startOfToday: Date
    ) {
        // Read file contents. For large sessions we could chunk, but the
        // 60s cache + mtime filter keeps this bounded.
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }

        // Cheap fast-path: split lines, quick-reject ones without a
        // timestamp field, then parse the rest.
        for rawLine in contents.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.contains("\"timestamp\":") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tsString = obj["timestamp"] as? String
            else { continue }

            guard let date = parseISO8601(tsString), date >= startOfToday else { continue }
            let hour = calendar.component(.hour, from: date)
            if (0..<24).contains(hour) {
                counts[hour] += 1
            }
        }
    }

    /// ISO 8601 parser tolerant of fractional seconds (Claude's timestamps
    /// look like `2026-04-15T18:21:08.353Z`).
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
