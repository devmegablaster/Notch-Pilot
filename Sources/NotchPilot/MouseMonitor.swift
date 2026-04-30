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
    /// The display that currently has a true-fullscreen frontmost app,
    /// or `nil` if nothing is in fullscreen. Multi-display: a fullscreen
    /// app on one screen shouldn't force the notch to hide on a different
    /// screen, so consumers compare this against the notch's own screen.
    @Published var fullscreenScreenID: CGDirectDisplayID? = nil

    /// Convenience for any binding that just wants a Bool. Stays in
    /// sync with `fullscreenScreenID`.
    var isFullscreen: Bool { fullscreenScreenID != nil }

    private let notchWidth: CGFloat
    private let notchHeight: CGFloat
    private var timer: Timer?
    private var fullscreenTickCounter = 0

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

        // AX queries cost a few ms of IPC — only poll fullscreen
        // state once per second, not every 100ms.
        fullscreenTickCounter += 1
        if fullscreenTickCounter >= 10 {
            fullscreenTickCounter = 0
            let fs = Self.checkFullscreenScreen()
            if fs != fullscreenScreenID {
                fullscreenScreenID = fs
            }
        }
    }

    /// Returns the display ID of the screen with a true-fullscreen
    /// frontmost app, or `nil` if nothing is fullscreen. Uses
    /// Accessibility (AXFullScreen) — the authoritative signal for
    /// true fullscreen across other apps — and AXPosition to find the
    /// screen that window lives on, so a fullscreen on display A
    /// doesn't force the notch to hide on display B.
    private static func checkFullscreenScreen() -> CGDirectDisplayID? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appRef, kAXFocusedWindowAttribute as CFString, &focusedValue
        ) == .success, let window = focusedValue else { return nil }
        let windowRef = window as! AXUIElement

        var fsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            windowRef, "AXFullScreen" as CFString, &fsValue
        ) == .success, let isFS = fsValue as? Bool, isFS else { return nil }

        // Find which display the focused window is on. AX returns
        // top-left-origin (Carbon) coords; convert to AppKit's
        // bottom-left-of-primary origin so we can match against
        // NSScreen frames.
        var posValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            windowRef, kAXPositionAttribute as CFString, &posValue
        ) == .success else { return nil }
        var pos = CGPoint.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)

        guard let primary = NSScreen.screens.first else { return nil }
        let appKit = CGPoint(x: pos.x, y: primary.frame.maxY - pos.y)
        // Probe one point inside the screen rect to avoid boundary
        // issues with `NSRect.contains` (max edges are exclusive).
        let probe = CGPoint(x: appKit.x + 1, y: appKit.y - 1)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) else {
            return nil
        }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screen.deviceDescription[key] as? CGDirectDisplayID
    }

    private var enterRect: CGRect { hitRect(margin: 18) }
    private var exitRect: CGRect { hitRect(margin: 60) }

    /// Returns the current pill rect in screen coordinates. Set by the
    /// NotchWindow once it's built so the hover area follows whatever
    /// snap zone the user has dragged the notch to. Falls back to a
    /// primary-screen-top-center default when nil (used briefly at
    /// startup before the window registers itself).
    var anchorRectProvider: (() -> CGRect)?

    /// Screen-coordinate rect covering the notch area plus a margin
    /// so the hover isn't fussy to trigger.
    private func hitRect(margin: CGFloat) -> CGRect {
        let base = anchorRectProvider?() ?? defaultAnchorRect()
        return CGRect(
            x: base.minX - margin,
            y: base.minY - margin,
            width: base.width + margin * 2,
            height: base.height + margin
        )
    }

    private func defaultAnchorRect() -> CGRect {
        guard let screen = NSScreen.main else { return .zero }
        let frame = screen.frame
        return CGRect(
            x: frame.midX - notchWidth / 2,
            y: frame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
    }
}
