import Foundation
import Combine

/// Aggregates Claude activity for a specific day from every session
/// jsonl in `~/.claude/projects/`, binned by hour. Designed to be cheap
/// (cached for 60s per-day) and safe to call from the main thread —
/// the actual scan runs on a background task.
///
/// The current day being displayed is controlled by `viewingDate`.
/// `advanceDay(by:)` moves backward/forward. "today" is a fresh scan;
/// past days are read from on-disk jsonls that still exist.
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

    /// The day currently being displayed. Defaults to today. Users
    /// can step backward/forward via the heatmap header arrows.
    @Published private(set) var viewingDate: Date = Calendar.current.startOfDay(for: Date())

    private let refreshInterval: TimeInterval = 60
    private var refreshTask: Task<Void, Never>?
    private var cachedDate: Date?

    /// Kick off a refresh if the currently-viewed day's data is older
    /// than `refreshInterval`, or if the day changed since the last
    /// refresh. Safe to call repeatedly — coalesced internally.
    func refreshIfNeeded() {
        if let last = lastRefreshed,
           cachedDate == viewingDate,
           Date().timeIntervalSince(last) < refreshInterval {
            return
        }
        if refreshTask != nil { return }

        let target = viewingDate
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.scan(day: target)
            }.value
            await MainActor.run {
                guard let self = self else { return }
                // Discard if the user switched days while the scan was
                // running; let the next refreshIfNeeded handle it.
                guard self.viewingDate == target else {
                    self.refreshTask = nil
                    self.refreshIfNeeded()
                    return
                }
                self.hourlyCounts = result.counts
                self.hourlyProjects = result.projects
                self.maxCount = result.counts.max() ?? 0
                self.totalToday = result.counts.reduce(0, +)
                self.lastRefreshed = Date()
                self.cachedDate = target
                self.refreshTask = nil
            }
        }
    }

    /// Shift `viewingDate` by `days` (negative = backward). Clamped
    /// so the user can't go into the future.
    func advanceDay(by days: Int) {
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .day, value: days, to: viewingDate) else { return }
        let today = cal.startOfDay(for: Date())
        if next > today { return }
        viewingDate = next
        // Force a refresh immediately since the day changed.
        cachedDate = nil
        refreshIfNeeded()
    }

    /// True if the displayed day is the current calendar day.
    var isViewingToday: Bool {
        Calendar.current.isDateInToday(viewingDate)
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

    private nonisolated static func scan(day: Date) -> (
        counts: [Int],
        projects: [[String: Int]]
    ) {
        var counts = Array(repeating: 0, count: 24)
        var perHourProjects = Array(repeating: [String: Int](), count: 24)
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: day)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return (counts, perHourProjects)
        }

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
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]
            ) else { continue }

            for fileURL in files where fileURL.pathExtension == "jsonl" {
                // Skip files that couldn't possibly contain events for
                // the target day — an mtime before the start-of-day
                // means the file was last written before the day began,
                // and a creation after the end-of-day means it didn't
                // exist yet. Either way, zero contributions.
                let resourceValues = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .creationDateKey]
                )
                let mtime = resourceValues?.contentModificationDate ?? .distantPast
                let ctime = resourceValues?.creationDate ?? .distantPast
                if mtime < startOfDay { continue }
                if ctime >= endOfDay { continue }

                scan(
                    fileURL,
                    into: &counts,
                    perHourProjects: &perHourProjects,
                    calendar: calendar,
                    startOfDay: startOfDay,
                    endOfDay: endOfDay
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
        startOfDay: Date,
        endOfDay: Date
    ) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }

        let lines = contents.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)

        // First pass: attribute every event in this jsonl to a project
        // name via the first cwd field we find. Falls back to the
        // directory-encoded name if no cwd is present.
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

        // Second pass: count events for the target day window.
        for rawLine in lines {
            let line = String(rawLine)
            guard line.contains("\"timestamp\":") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tsString = obj["timestamp"] as? String
            else { continue }

            guard let date = parseISO8601(tsString),
                  date >= startOfDay,
                  date < endOfDay
            else { continue }

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
