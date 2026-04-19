import AppKit

@main
struct NotchPilotApp {
    @MainActor
    static func main() {
        // Dual-mode binary: when Claude Code invokes us as a hook, skip
        // AppKit entirely and run the stdio ↔ socket bridge. Must happen
        // before any NSApplication access so we don't bounce the Dock icon
        // or steal focus on every hook firing.
        if CommandLine.arguments.contains("--hook") {
            HookClient.run()
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
