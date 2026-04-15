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
