import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NotchWindow?
    private var onboardingWindow: OnboardingWindow?
    private let monitor = ClaudeMonitor()
    private let hookBridge = HookBridge()
    private let preferences = BuddyPreferences()
    private let heatmap = HeatmapAggregator()
    private var mouseMonitor: MouseMonitor?

    /// UserDefaults key — set to `true` after the onboarding sequence
    /// completes so future launches skip it.
    private static let onboardingCompletedKey = "onboardingCompleted"

    func applicationDidFinishLaunching(_ notification: Notification) {
        HookInstaller.installIfNeeded()
        hookBridge.start()

        // Always start the regular notch window underneath the intro —
        // the onboarding overlay ends by fading out its backdrop to
        // reveal the notch in its final position, which means the notch
        // needs to already be there.
        startNotchWindow()

        // Force the onboarding on every launch when the debug env var
        // is set (useful for iterating on the intro animation without
        // blowing away UserDefaults).
        let forceIntro = ProcessInfo.processInfo.environment["NOTCH_PILOT_FORCE_ONBOARDING"] != nil
        let alreadyOnboarded = UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
        if forceIntro || !alreadyOnboarded {
            showOnboarding()
        }
    }

    private func startNotchWindow() {
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

    private func showOnboarding() {
        let (nw, nh) = Self.notchGeometry()
        let window = OnboardingWindow(
            preferences: preferences,
            notchWidth: nw,
            notchHeight: nh
        ) { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
            self.onboardingWindow?.orderOut(nil)
            self.onboardingWindow = nil
        }
        self.onboardingWindow = window
        window.orderFront(nil)
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
