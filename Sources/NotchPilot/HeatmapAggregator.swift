import Foundation
import Combine

/// Aggregates today's Claude activity from every session jsonl in
/// `~/.claude/projects/`, binned by hour. Designed to be cheap to query
/// (cached for 60s) and safe to call from the main thread — the actual
/// scan runs on a background task.
@MainActor
final class HeatmapAggregator: ObservableObject {
    @Published private(set) var hourlyCounts: [Int] = Array(repeating: 0, count: 24)
    /// Per-hour project-name → event-count breakdown. Used to surface a
    /// per-cell tooltip showing which projects were active in that hour.
    @Published private(set) var hourlyProjects: [[String: Int]] =
        Array(repeating: [:], count: 24)
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
            let result = await Task.detached(priority: .utility) {
                Self.scanToday()
            }.value
            await MainActor.run {
                guard let self = self else { return }
                self.hourlyCounts = result.counts
                self.hourlyProjects = result.projects
                self.maxCount = result.counts.max() ?? 0
                self.totalToday = result.counts.reduce(0, +)
                self.lastRefreshed = Date()
                self.refreshTask = nil
            }
        }
    }

    /// Returns the projects active during a given hour, sorted by event
    /// count descending. Used by the heatmap hover row.
    func projects(forHour hour: Int) -> [(name: String, count: Int)] {
        guard (0..<24).contains(hour) else { return [] }
        return hourlyProjects[hour]
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Scan (runs off main)

    private nonisolated static func scanToday() -> (
        counts: [Int],
        projects: [[String: Int]]
    ) {
        var counts = Array(repeating: 0, count: 24)
        var perHourProjects = Array(repeating: [String: Int](), count: 24)
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")

        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (counts, perHourProjects)
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

                scan(
                    fileURL,
                    into: &counts,
                    perHourProjects: &perHourProjects,
                    calendar: calendar,
                    startOfToday: startOfToday
                )
            }
        }
        return (counts, perHourProjects)
    }

    private nonisolated static func scan(
        _ url: URL,
        into counts: inout [Int],
        perHourProjects: inout [[String: Int]],
        calendar: Calendar,
        startOfToday: Date
    ) {
        // Read file contents. For large sessions we could chunk, but the
        // 60s cache + mtime filter keeps this bounded.
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }

        let lines = contents.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)

        // First pass: find a cwd field (any line that has one) so we can
        // attribute every event in this jsonl to a project name. Falls
        // back to the directory-encoded name if no cwd is present.
        var project: String?
        for rawLine in lines {
            let line = String(rawLine)
            guard line.contains("\"cwd\":") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty
            else { continue }
            project = (cwd as NSString).lastPathComponent
            break
        }
        if project == nil {
            project = decodeProjectDirName(url.deletingLastPathComponent().lastPathComponent)
        }
        let projectName = project ?? "unknown"

        // Second pass: count events.
        for rawLine in lines {
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
                perHourProjects[hour][projectName, default: 0] += 1
            }
        }
    }

    /// Decode a `~/.claude/projects/-Users-foo-myproject` style directory
    /// name back to its trailing component. Lossy if the actual path
    /// contained hyphens, but good enough as a fallback for the heatmap.
    private nonisolated static func decodeProjectDirName(_ encoded: String) -> String {
        let path = encoded.replacingOccurrences(of: "-", with: "/")
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? encoded : name
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
