import Foundation
import AppKit
import Combine

/// Polls the mouse position 10× per second and publishes whether the
/// cursor is currently inside the notch hit area. Used to summon the
/// buddy on hover even when no Claude session is active, so the user can
/// always access the appearance picker / quit menu.
///
/// We poll rather than use `NSEvent.addGlobalMonitorForEvents(.mouseMoved)`
/// because global mouse-move monitors don't fire reliably when our own
/// app is in the foreground, and we want the hover to work *regardless*
/// of which app has focus. `NSEvent.mouseLocation` is a cheap sync read
/// of the system mouse state.
@MainActor
final class MouseMonitor: ObservableObject {
    @Published var isHoveringNotch = false
    @Published var isFullscreen = false

    private let notchWidth: CGFloat
    private let notchHeight: CGFloat
    private var timer: Timer?

    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Hysteresis: use a tight rect to enter the hover state and a
        // larger rect to exit it. Without this, hovering right at the
        // edge of the hit area causes rapid toggling — each 100ms poll
        // sees the cursor cross the boundary as pixel-level jitter
        // nudges it in and out, which flickers the panel.
        let rect = isHoveringNotch ? exitRect : enterRect
        let inside = rect.contains(NSEvent.mouseLocation)
        if inside != isHoveringNotch {
            isHoveringNotch = inside
        }

        // Fullscreen detection: check if the main screen's visible
        // frame equals its full frame — when an app is fullscreen,
        // the menu bar is hidden and visibleFrame.height == frame.height.
        let fs = Self.checkFullscreen()
        if fs != isFullscreen {
            isFullscreen = fs
        }
    }

    /// Returns true if the frontmost app is in native fullscreen.
    /// Checks if the frontmost app has a window that fills the screen
    /// below the notch (Y ≤ safeAreaInsets.top, full width, full
    /// visible height). In non-fullscreen, windows start below the
    /// menu bar (Y ≈ 44 on notched Macs with menu bar visible).
    /// In fullscreen, the menu bar hides and windows start at Y ≈ 39
    /// (the notch height), filling the visible area.
    private static func checkFullscreen() -> Bool {
        guard let screen = NSScreen.main else { return false }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }

        // In fullscreen, the menu bar auto-hides. Check if the menu
        // bar is hidden by comparing visible frame to full frame.
        // On notched Macs: non-fullscreen visibleFrame.height ≈ frame.height - 39
        // (menu bar takes ~39px). In fullscreen, visibleFrame stays the
        // same but the menu bar is auto-hidden — we can detect this by
        // checking if NSMenu.menuBarVisible() is false.
        if !NSMenu.menuBarVisible() {
            return true
        }

        // Fallback: check if the frontmost app owns a window that
        // fills the entire visible area starting right below the notch.
        let pid = frontApp.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let notchHeight = screen.safeAreaInsets.top
        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"],
                  let h = bounds["Height"],
                  let y = bounds["Y"],
                  (window[kCGWindowLayer as String] as? Int) == 0
            else { continue }

            // Fullscreen: window at Y=notchHeight, full width, fills
            // the rest of the screen.
            if y <= notchHeight + 1
                && w >= screen.frame.width - 2
                && h >= screen.frame.height - notchHeight - 2 {
                return true
            }
        }
        return false
    }

    private var enterRect: CGRect { hitRect(margin: 18) }
    private var exitRect: CGRect { hitRect(margin: 60) }

    /// Screen-coordinate rect covering the notch area plus a margin
    /// so the hover isn't fussy to trigger.
    private func hitRect(margin: CGFloat) -> CGRect {
        guard let screen = NSScreen.main else { return .zero }
        let frame = screen.frame
        return CGRect(
            x: frame.midX - notchWidth / 2 - margin,
            y: frame.maxY - notchHeight - margin,
            width: notchWidth + margin * 2,
            height: notchHeight + margin
        )
    }
}
