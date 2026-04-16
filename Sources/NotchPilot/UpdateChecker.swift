import Foundation
import AppKit

/// Polls the GitHub Releases API for the latest Notch Pilot version
/// and compares it against the running app's `CFBundleShortVersionString`.
/// Publishes the result so the UI can show an unobtrusive upgrade badge.
///
/// Supports two upgrade paths:
/// - **Homebrew**: detects brew on disk → runs `brew upgrade --cask notch-pilot`
/// - **Direct download**: downloads the DMG from the GitHub release and opens it
@MainActor
final class UpdateChecker: ObservableObject {
    enum UpdateState: Equatable {
        case idle
        case updating
        case failed(String)
    }

    @Published private(set) var latestVersion: String?
    @Published private(set) var updateAvailable = false
    @Published private(set) var releaseURL: URL?
    @Published private(set) var dmgURL: URL?
    @Published private(set) var state: UpdateState = .idle
    @Published var nodeMissing = false
    @Published var nodeBannerDismissed = false

    private let owner = "devmegablaster"
    private let repo = "Notch-Pilot"
    private var checkTask: Task<Void, Never>?

    /// The effective version to compare against. Uses the running app's
    /// bundle version if available (real .app build). For debug builds
    /// (swift run) where there's no Info.plist, falls back to the
    /// installed /Applications copy's version so we don't perpetually
    /// show "update available" when the installed app is already current.
    var currentVersion: String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        if let v = bundleVersion, v != "0.0.0" && !v.isEmpty {
            return v
        }
        // Debug build — check the installed .app's version instead
        if let installed = Bundle(path: "/Applications/Notch Pilot.app"),
           let v = installed.infoDictionary?["CFBundleShortVersionString"] as? String {
            return v
        }
        return "0.0.0"
    }

    /// Whether Homebrew is available on this machine.
    var hasHomebrew: Bool { brewPath != nil }

    /// Resolved path to the `brew` binary, or nil.
    private var brewPath: String? {
        // Apple Silicon default, then Intel default
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Start a background loop that checks every 30 minutes.
    func startPeriodicChecks() {
        guard checkTask == nil else { return }
        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            }
        }
    }

    func check() async {
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200
            else { return }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String
            else { return }

            // Strip leading "v" from tag (e.g. "v0.3.0" → "0.3.0")
            let remote = tagName.hasPrefix("v")
                ? String(tagName.dropFirst())
                : tagName

            // Find the .dmg asset URL from the release
            var foundDMG: URL? = nil
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".dmg"),
                       let downloadURL = asset["browser_download_url"] as? String {
                        foundDMG = URL(string: downloadURL)
                        break
                    }
                }
            }

            latestVersion = remote
            releaseURL = URL(string: htmlURL)
            dmgURL = foundDMG
            updateAvailable = isNewer(remote: remote, local: currentVersion)
        } catch {
            // Network failure — silently ignore, will retry next cycle.
        }
    }

    /// Perform the update. Uses Homebrew if available, otherwise
    /// downloads the DMG and opens it for the user to drag-install.
    func performUpdate() {
        guard updateAvailable, state != .updating else { return }
        state = .updating

        Task {
            if let brew = brewPath {
                await updateViaBrew(brew)
            } else {
                await updateViaDMG()
            }
        }
    }

    // MARK: - Homebrew path

    private func updateViaBrew(_ brewPath: String) async {
        let success = await runBrewUpgrade(brewPath)
        if success {
            // Don't rely on the cask postflight — relaunch ourselves
            // with the same detached script used by the DMG path.
            let appPath = "/Applications/Notch Pilot.app"
            let pid = ProcessInfo.processInfo.processIdentifier
            let relaunchScript = FileManager.default.temporaryDirectory
                .appendingPathComponent("notchpilot-relaunch.sh")
            let scriptContent = """
                #!/bin/sh
                while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
                sleep 0.5
                open -a "\(appPath)"
                rm -f "\(relaunchScript.path)"
                """
            do {
                try scriptContent.write(to: relaunchScript, atomically: true, encoding: .utf8)
                chmod(relaunchScript.path, 0o755)
                let sh = Process()
                sh.launchPath = "/bin/sh"
                sh.arguments = ["-c", "nohup \"\(relaunchScript.path)\" &>/dev/null &"]
                sh.standardOutput = FileHandle.nullDevice
                sh.standardError = FileHandle.nullDevice
                try sh.run()
            } catch {
                // If the script fails, at least the upgrade happened
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        } else {
            state = .failed("brew upgrade failed")
        }
    }

    private nonisolated func runBrewUpgrade(_ brewPath: String) async -> Bool {
        await withCheckedContinuation { cont in
            let task = Process()
            task.launchPath = brewPath
            task.arguments = ["upgrade", "--cask", "notch-pilot"]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                cont.resume(returning: task.terminationStatus == 0)
            } catch {
                cont.resume(returning: false)
            }
        }
    }

    // MARK: - Direct DMG download path
    //
    // Flow: download DMG → mount → copy .app to /Applications → unmount → relaunch.
    // The old app is replaced in-place. macOS doesn't lock the .app bundle
    // on disk while it's running (the binary is paged into memory), so the
    // copy succeeds even though we're still alive. We relaunch from the
    // new bundle immediately after.

    private func updateViaDMG() async {
        guard let url = dmgURL else {
            if let release = releaseURL {
                NSWorkspace.shared.open(release)
            }
            state = .idle
            return
        }

        do {
            // 1. Download
            let (fileURL, _) = try await URLSession.shared.download(from: url)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("NotchPilot-update.dmg")
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.moveItem(at: fileURL, to: tmp)

            // 2. Mount the DMG silently
            let mountPoint = try await mountDMG(tmp)

            // 3. Find the .app inside
            let contents = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: mountPoint),
                includingPropertiesForKeys: nil
            )
            guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
                try? await unmountDMG(mountPoint)
                state = .failed("No .app found in DMG")
                return
            }

            // 4. Figure out where to install + what to relaunch.
            // If running from an .app bundle, replace it in place.
            // If running from a debug build (swift run), install to /Applications.
            let runningBundle = Bundle.main.bundlePath
            let isAppBundle = runningBundle.hasSuffix(".app")
            let dest: URL
            if isAppBundle {
                dest = URL(fileURLWithPath: runningBundle)
            } else {
                dest = URL(fileURLWithPath: "/Applications/\(appBundle.lastPathComponent)")
            }

            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: appBundle, to: dest)

            // 5. Clear quarantine (must complete before relaunch)
            let xattr = Process()
            xattr.launchPath = "/usr/bin/xattr"
            xattr.arguments = ["-dr", "com.apple.quarantine", dest.path]
            try? xattr.run()
            xattr.waitUntilExit()

            // 6. Ad-hoc codesign so Gatekeeper doesn't block it
            let codesign = Process()
            codesign.launchPath = "/usr/bin/codesign"
            codesign.arguments = ["--force", "--deep", "--sign", "-", dest.path]
            codesign.standardOutput = Pipe()
            codesign.standardError = Pipe()
            try? codesign.run()
            codesign.waitUntilExit()

            // 7. Unmount + clean up
            try? await unmountDMG(mountPoint)
            try? FileManager.default.removeItem(at: tmp)

            // 8. Relaunch — write a tiny script to disk and launch
            // it fully detached via launchd (via `open`). A Process()
            // child dies when the parent terminates, but a script
            // launched via /usr/bin/open as its own process survives.
            let pid = ProcessInfo.processInfo.processIdentifier
            let relaunchScript = FileManager.default.temporaryDirectory
                .appendingPathComponent("notchpilot-relaunch.sh")
            let scriptContent = """
                #!/bin/sh
                while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
                sleep 0.5
                open -a "\(dest.path)"
                rm -f "\(relaunchScript.path)"
                """
            try scriptContent.write(to: relaunchScript, atomically: true, encoding: .utf8)
            chmod(relaunchScript.path, 0o755)

            // Launch detached — nohup + setsid equivalent
            let sh = Process()
            sh.launchPath = "/bin/sh"
            sh.arguments = ["-c", "nohup \"\(relaunchScript.path)\" &>/dev/null &"]
            sh.standardOutput = FileHandle.nullDevice
            sh.standardError = FileHandle.nullDevice
            try sh.run()

            // Give the background process time to fork, then quit
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)

        } catch {
            state = .failed("Update failed")
        }
    }

    private nonisolated func mountDMG(_ path: URL) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let task = Process()
            task.launchPath = "/usr/bin/hdiutil"
            task.arguments = ["attach", path.path, "-nobrowse", "-plist"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                // Parse the plist output to find mount point
                guard let plist = try? PropertyListSerialization.propertyList(
                    from: data, format: nil
                ) as? [String: Any],
                      let entities = plist["system-entities"] as? [[String: Any]]
                else {
                    cont.resume(throwing: NSError(domain: "UpdateChecker", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to parse mount output"]))
                    return
                }
                for entity in entities {
                    if let mp = entity["mount-point"] as? String {
                        cont.resume(returning: mp)
                        return
                    }
                }
                cont.resume(throwing: NSError(domain: "UpdateChecker", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No mount point found"]))
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private nonisolated func unmountDMG(_ mountPoint: String) async throws {
        let task = Process()
        task.launchPath = "/usr/bin/hdiutil"
        task.arguments = ["detach", mountPoint, "-quiet"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
    }

    // MARK: - Semver comparison

    /// Returns true when `remote` > `local`.
    private func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
