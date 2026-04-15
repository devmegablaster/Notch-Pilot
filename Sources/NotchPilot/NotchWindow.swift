import AppKit
import SwiftUI

final class NotchWindow: NSPanel {
    private let notchWidth: CGFloat
    private let notchHeight: CGFloat

    // Cached geometry for the last-requested collapsed pill size so the
    // window can follow text-width changes as Claude's status evolves.
    private var lastCollapsedWidth: CGFloat = 0

    init(
        monitor: ClaudeMonitor,
        hookBridge: HookBridge,
        preferences: BuddyPreferences,
        heatmap: HeatmapAggregator,
        mouseMonitor: MouseMonitor
    ) {
        guard let screen = NSScreen.main else {
            fatalError("no main screen")
        }
        let screenFrame = screen.frame

        let nh: CGFloat = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : 32
        var nw: CGFloat = 200
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            let derived = screenFrame.width - leftArea.width - rightArea.width
            if derived > 40 {
                nw = derived
            }
        }

        self.notchWidth = nw
        self.notchHeight = nh

        // Start with a tiny 1×1 frame at the top-center. The first state
        // callback from the view will resize us into place.
        let initialRect = NSRect(
            x: screenFrame.midX - 0.5,
            y: screenFrame.maxY - 1,
            width: 1,
            height: 1
        )

        super.init(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .statusBar
        self.isMovable = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.alphaValue = 0

        let view = NotchContentView(
            monitor: monitor,
            hookBridge: hookBridge,
            heatmap: heatmap,
            mouseMonitor: mouseMonitor,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            onVisibilityChange: { [weak self] visible in
                self?.setVisible(visible)
            },
            onCollapsedSizeChange: { [weak self] width in
                self?.updateCollapsed(width: width)
            },
            onExpandedChange: { [weak self] expanded in
                self?.updateExpanded(expanded)
            }
        )
        .environmentObject(preferences)

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: initialRect.size)
        hosting.autoresizingMask = [.width, .height]
        self.contentView = hosting
    }

    func show() {
        // Do not force-show on launch. The first onVisibilityChange(true)
        // callback from NotchContentView — fired the moment it detects a
        // running claude process — brings us on screen.
    }

    // Never become the key window. `.nonactivatingPanel` already stops
    // the panel from activating our app on click — but without this,
    // the panel still becomes the *key* window, which steals keyboard
    // focus from whatever was previously key (your editor, terminal,
    // etc). The side effect is that keyboard shortcuts bound to panel
    // buttons (Enter / Esc on Allow / Deny) and typing in the filter
    // bar stop working. Button clicks still work because they fire
    // on mouse events regardless of key state.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Frame helpers

    private func collapsedFrame(width: CGFloat) -> NSRect {
        guard let screen = NSScreen.main else { return .zero }
        let screenFrame = screen.frame
        // Horizontally center the physical notch, not the window. The left
        // section of the pill is `leftSectionWidth` (56) wide and sits to
        // the left of the notch, so we shift the window origin left by
        // (leftSectionWidth + notchWidth/2) from screen center.
        let leftSection: CGFloat = 56
        let x = screenFrame.midX - leftSection - notchWidth / 2
        let y = screenFrame.maxY - notchHeight
        return NSRect(x: x, y: y, width: width, height: notchHeight)
    }

    /// Same as `collapsedFrame` but pushed above the visible screen edge so
    /// it can slide DOWN into position on appear and slide UP on hide.
    private func hiddenFrame(width: CGFloat) -> NSRect {
        guard let screen = NSScreen.main else { return .zero }
        var f = collapsedFrame(width: width)
        // Move the window's top up by ~1.5x its own height so the entire
        // pill is above the screen edge before the slide-down begins.
        f.origin.y = screen.frame.maxY + notchHeight * 0.6
        return f
    }

    private func expandedFrame() -> NSRect {
        guard let screen = NSScreen.main else { return .zero }
        let screenFrame = screen.frame
        let w: CGFloat = 560
        let h: CGFloat = 460 // panel + shadow headroom
        return NSRect(
            x: screenFrame.midX - w / 2,
            y: screenFrame.maxY - h,
            width: w,
            height: h
        )
    }

    // MARK: - State callbacks

    private func setVisible(_ visible: Bool) {
        // SwiftUI handles the collapse-into-notch animation via a scale
        // transition on the collapsed pill. The window just needs to:
        //   1) be ordered onto the screen so SwiftUI has somewhere to draw
        //   2) let mouse events through while nothing is visible
        if visible {
            self.ignoresMouseEvents = false
            self.alphaValue = 1
            if !self.isVisible {
                orderFrontRegardless()
            }
        } else {
            self.ignoresMouseEvents = true
        }
    }

    private func updateCollapsed(width: CGFloat) {
        lastCollapsedWidth = width
        // Only apply if we're currently in the collapsed state. The
        // expanded-frame callback owns the frame while expanded.
        let currentFrame = self.frame
        let expected = expandedFrame()
        if currentFrame.size != expected.size {
            setFrame(collapsedFrame(width: width), display: true, animate: false)
        }
    }

    private func updateExpanded(_ expanded: Bool) {
        let target = expanded ? expandedFrame() : collapsedFrame(width: lastCollapsedWidth)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(target, display: true)
        }
    }
}
