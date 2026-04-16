import AppKit
import SwiftUI

final class NotchWindow: NSPanel {
    private let notchWidth: CGFloat
    private let notchHeight: CGFloat

    // Cached geometry for the last-requested collapsed pill size so
    // the window can follow width and height changes — width for
    // status-text length, height for the speech pop-out.
    private var lastCollapsedSize: CGSize = .zero

    init(
        monitor: ClaudeMonitor,
        hookBridge: HookBridge,
        preferences: BuddyPreferences,
        heatmap: HeatmapAggregator,
        usage: UsageAggregator,
        mouseMonitor: MouseMonitor,
        speechController: SpeechController,
        updateChecker: UpdateChecker
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
            usage: usage,
            mouseMonitor: mouseMonitor,
            speechController: speechController,
            updateChecker: updateChecker,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            onVisibilityChange: { [weak self] visible in
                self?.setVisible(visible)
            },
            onCollapsedSizeChange: { [weak self] size in
                self?.updateCollapsed(size: size)
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

    private func collapsedFrame(size: CGSize) -> NSRect {
        guard let screen = NSScreen.main else { return .zero }
        let screenFrame = screen.frame
        // Horizontally center the physical notch, not the window. The
        // left section of the pill is `leftSectionWidth` (56) wide and
        // sits to the left of the notch, so we shift the window origin
        // left by (leftSectionWidth + notchWidth/2) from screen center.
        // Speech pop-outs keep the same horizontal footprint — only
        // the height changes — so the offset is identical.
        let leftSection: CGFloat = 56
        let x = screenFrame.midX - leftSection - notchWidth / 2
        let y = screenFrame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
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

    private func updateCollapsed(size: CGSize) {
        lastCollapsedSize = size
        // Only apply if we're currently in the collapsed state. The
        // expanded-frame callback owns the frame while expanded.
        let currentFrame = self.frame
        let expected = expandedFrame()
        if currentFrame.size != expected.size {
            // Animate so the speech pop-out physically grows rather
            // than hard-resizing to its new frame.
            let target = collapsedFrame(size: size)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(target, display: true)
            }
        }
    }

    private func updateExpanded(_ expanded: Bool) {
        let target = expanded ? expandedFrame() : collapsedFrame(size: lastCollapsedSize)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(target, display: true)
        }
    }
}
