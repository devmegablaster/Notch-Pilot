import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NotchWindow?
    private let monitor = ClaudeMonitor()
    private let hookBridge = HookBridge()
    private let preferences = BuddyPreferences()
    private let heatmap = HeatmapAggregator()
    private var mouseMonitor: MouseMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        HookInstaller.installIfNeeded()
        hookBridge.start()

        // Derive notch geometry once here so both the window and the
        // mouse monitor use the same values.
        let (nw, nh) = Self.notchGeometry()
        let mm = MouseMonitor(notchWidth: nw, notchHeight: nh)
        self.mouseMonitor = mm

        window = NotchWindow(
            monitor: monitor,
            hookBridge: hookBridge,
            preferences: preferences,
            heatmap: heatmap,
            mouseMonitor: mm
        )
        window?.show()
        monitor.start()
        mm.start()
    }

    private static func notchGeometry() -> (width: CGFloat, height: CGFloat) {
        guard let screen = NSScreen.main else { return (200, 32) }
        let nh: CGFloat = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : 32
        var nw: CGFloat = 200
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let derived = screen.frame.width - leftArea.width - rightArea.width
            if derived > 40 {
                nw = derived
            }
        }
        return (nw, nh)
    }
}
