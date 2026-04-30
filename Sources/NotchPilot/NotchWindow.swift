import AppKit
import SwiftUI
import Combine

final class NotchWindow: NSPanel {
    private let notchWidth: CGFloat
    private let notchHeight: CGFloat
    private let preferences: BuddyPreferences

    /// Padding from the screen's left/right edge for non-center zones.
    private static let edgePadding: CGFloat = 10

    /// Vertical breathing room from the top of the screen for floating
    /// positions. `topCenter` on a notched screen stays flush so the
    /// pill flows seamlessly out of the hardware notch; everything else
    /// gets a small gap so it doesn't look stuck to the menu-bar edge.
    private static let floatingTopGap: CGFloat = 2

    /// Width / height of the expanded panel (kept fixed across positions
    /// so the panel layout doesn't need to reflow).
    private static let expandedPanelWidth: CGFloat = 560
    private static let expandedPanelHeight: CGFloat = 460

    // Cached geometry for the last-requested collapsed pill size so
    // the window can follow width and height changes — width for
    // status-text length, height for the speech pop-out.
    private var lastCollapsedSize: CGSize = .zero
    /// Tracks whether the panel is currently in expanded-frame mode.
    /// Used to no-op `updateCollapsed` while expanded so the SwiftUI
    /// re-render that fires both onChange(of:collapsedSize) and
    /// onChange(of:effectivelyExpanded) doesn't have the collapse
    /// callback clobber the expand animation.
    private var isExpanded = false
    /// True between the drag-threshold being crossed and mouseUp. While
    /// set, frame updates from prefs/state callbacks are suppressed so
    /// we don't fight the drag.
    private var isUserDragging = false
    private var dragStartMouseInScreen: NSPoint = .zero
    private var dragStartWindowOrigin: NSPoint = .zero
    private var dragMaxDistance: CGFloat = 0
    /// Drag must travel at least this many points before we treat the
    /// gesture as a move rather than a click.
    private static let dragThreshold: CGFloat = 5

    private var prefsCancellables: Set<AnyCancellable> = []

    /// Hit-test wrapper around the SwiftUI hosting view. Lets clicks in
    /// transparent regions of the window (outside the visible pill /
    /// panel) pass through to the menu bar below. Set immediately after
    /// super.init — declared IUO so we can build it with closures that
    /// capture [weak self] (Swift forbids that before super.init).
    private var clickHost: ClickThroughHostingView<AnyView>!

    /// Translucent overlay shown during a drag at whichever snap zone
    /// the pill would land in if released right now. Created lazily.
    private lazy var snapPreview = SnapPreviewWindow()

    init(
        monitor: ClaudeMonitor,
        hookBridge: HookBridge,
        preferences: BuddyPreferences,
        heatmap: HeatmapAggregator,
        usage: UsageAggregator,
        mouseMonitor: MouseMonitor,
        speechController: SpeechController,
        updateChecker: UpdateChecker,
        hotkeys: GlobalHotkeys
    ) {
        // Notch dimensions come from a *notched* display whenever one
        // is connected, even if the user happens to be focused on an
        // external monitor at launch — otherwise we'd cache the
        // 200/32 defaults forever and the silhouette wouldn't be wide
        // enough to cover the actual hardware notch when the user
        // dragged back to the MacBook screen.
        guard let mainScreen = NSScreen.main else {
            fatalError("no main screen")
        }
        let dimensionsScreen = NSScreen.screens.first(where: {
            $0.safeAreaInsets.top > 0
        }) ?? mainScreen

        let nh: CGFloat = dimensionsScreen.safeAreaInsets.top > 0
            ? dimensionsScreen.safeAreaInsets.top
            : 32
        var nw: CGFloat = 200
        if let leftArea = dimensionsScreen.auxiliaryTopLeftArea,
           let rightArea = dimensionsScreen.auxiliaryTopRightArea {
            let derived = dimensionsScreen.frame.width - leftArea.width - rightArea.width
            if derived > 40 {
                nw = derived
            }
        }

        self.notchWidth = nw
        self.notchHeight = nh
        self.preferences = preferences

        let screenFrame = mainScreen.frame

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
            hotkeys: hotkeys,
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

        let host = ClickThroughHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: initialRect.size)
        host.autoresizingMask = [.width, .height]
        self.clickHost = host
        self.contentView = host

        // Hover detection follows wherever the pill is currently sitting,
        // so dragging it to a different zone / screen still summons it
        // on hover.
        mouseMonitor.anchorRectProvider = { [weak self] in
            self?.currentPillRect ?? .zero
        }

        // Re-position when the user picks a different zone or the
        // saved screen disappears / reappears.
        preferences.$notchPosition
            .dropFirst()
            .sink { [weak self] _ in self?.repositionForCurrentState() }
            .store(in: &prefsCancellables)
        preferences.$notchScreenID
            .dropFirst()
            .sink { [weak self] _ in self?.repositionForCurrentState() }
            .store(in: &prefsCancellables)
        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in self?.handleScreenChange() }
        .store(in: &prefsCancellables)
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

    /// The screen the notch is currently anchored to. Honors the user's
    /// saved choice; falls back to a notched display, then the system
    /// primary, when the saved display isn't connected.
    private var currentScreen: NSScreen {
        Self.resolveScreen(savedID: preferences.notchScreenID)
    }

    /// Stable screen resolver shared with `NotchContentView` so the
    /// content's silhouette decision and the window's positioning agree
    /// on which display the notch lives on. Avoids `NSScreen.main` —
    /// that one tracks keyboard focus and would flip every time the
    /// user clicks an app on a different monitor.
    static func resolveScreen(savedID: CGDirectDisplayID?) -> NSScreen {
        if let id = savedID,
           let match = NSScreen.screens.first(where: { displayID(of: $0) == id }) {
            return match
        }
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.screens.first ?? NSScreen.main!
    }

    /// `topCenter` keeps the original 560-wide window so the
    /// expand/collapse animation has horizontal continuity. Every other
    /// zone uses a tight window matching the pill — the smaller
    /// footprint also means we don't need any click pass-through trickery
    /// for those positions.
    private func collapsedFrame(size: CGSize) -> NSRect {
        let screen = currentScreen
        let f = screen.frame
        let pos = preferences.notchPosition
        let topGap = topGapForCurrentState(on: screen)
        if pos == .topCenter {
            let w: CGFloat = Self.expandedPanelWidth
            return NSRect(
                x: f.midX - w / 2,
                y: f.maxY - size.height - topGap,
                width: w,
                height: size.height
            )
        }
        let x = horizontalOrigin(for: pos, contentWidth: size.width, on: screen)
        return NSRect(
            x: x,
            y: f.maxY - size.height - topGap,
            width: size.width,
            height: size.height
        )
    }

    private func expandedFrame() -> NSRect {
        let screen = currentScreen
        let f = screen.frame
        let pos = preferences.notchPosition
        let w: CGFloat = Self.expandedPanelWidth
        let h: CGFloat = Self.expandedPanelHeight
        let topGap = topGapForCurrentState(on: screen)
        let x = horizontalOrigin(for: pos, contentWidth: w, on: screen)
        return NSRect(x: x, y: f.maxY - h - topGap, width: w, height: h)
    }

    /// Compute the window's left edge for a given zone. The non-end
    /// zones center the window on a fraction of screen width, then we
    /// clamp so neither edge of the window falls off-screen (matters
    /// for the wide expanded panel on narrow displays).
    private func horizontalOrigin(
        for position: NotchPosition,
        contentWidth: CGFloat,
        on screen: NSScreen
    ) -> CGFloat {
        let f = screen.frame
        let minX = f.minX + Self.edgePadding
        let maxX = f.maxX - contentWidth - Self.edgePadding
        switch position {
        case .topLeft:
            return minX
        case .topRight:
            return maxX
        default:
            let center = f.minX + f.width * position.horizontalAnchor
            let raw = center - contentWidth / 2
            return min(max(raw, minX), maxX)
        }
    }

    /// Floating positions get a small gap from the top of the screen.
    /// `topCenter` on a notched screen stays flush so the pill keeps
    /// flowing seamlessly out of the hardware notch.
    private func topGapForCurrentState(on screen: NSScreen) -> CGFloat {
        let isHardwareNotchSlot =
            preferences.notchPosition == .topCenter
            && screen.safeAreaInsets.top > 0
        return isHardwareNotchSlot ? 0 : Self.floatingTopGap
    }

    /// Pulls the CG display ID off an NSScreen. Used to remember which
    /// physical display the user pinned the notch to.
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screen.deviceDescription[key] as? CGDirectDisplayID
    }

    /// The pill's actual rect on screen — used by `MouseMonitor` to size
    /// the hover hit area. In `topCenter` the pill is narrower than the
    /// 560-wide window (centered inside it); in every other zone the
    /// window already matches the pill, so we just use the window left
    /// edge.
    var currentPillRect: CGRect {
        let f = self.frame
        let h = lastCollapsedSize.height > 0 ? lastCollapsedSize.height : notchHeight
        let pillWidth = lastCollapsedSize.width > 0 ? lastCollapsedSize.width : notchWidth
        let x: CGFloat
        if preferences.notchPosition == .topCenter {
            x = f.midX - pillWidth / 2
        } else {
            x = f.minX
        }
        return CGRect(x: x, y: f.maxY - h, width: pillWidth, height: h)
    }

    /// Recompute and apply the right frame for the current state.
    /// Called from prefs / screen-change observers.
    private func repositionForCurrentState() {
        guard !isUserDragging else { return }
        let target: NSRect
        if isExpanded {
            target = expandedFrame()
        } else if lastCollapsedSize.width > 0 {
            target = collapsedFrame(size: lastCollapsedSize)
        } else {
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(target, display: true)
        }
    }

    /// If the saved screen has been unplugged, drop the saved ID so the
    /// next reposition falls back to the primary. Then reposition to
    /// land in the right place on whatever screen we ended up on.
    private func handleScreenChange() {
        if let saved = preferences.notchScreenID,
           !NSScreen.screens.contains(where: { Self.displayID(of: $0) == saved }) {
            preferences.notchScreenID = nil
        } else {
            repositionForCurrentState()
        }
    }

    // MARK: - Drag-to-move

    /// We hijack mouse events at the window level so the user can drag
    /// the pill / panel to a new snap zone. A small distance threshold
    /// distinguishes a real drag from a click — sub-threshold movement
    /// still gets dispatched normally so SwiftUI button taps work.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartMouseInScreen = NSEvent.mouseLocation
            dragStartWindowOrigin = self.frame.origin
            dragMaxDistance = 0
            isUserDragging = false
            super.sendEvent(event)
        case .leftMouseDragged:
            let cursor = NSEvent.mouseLocation
            let dx = cursor.x - dragStartMouseInScreen.x
            let dy = cursor.y - dragStartMouseInScreen.y
            let dist = sqrt(dx * dx + dy * dy)
            dragMaxDistance = max(dragMaxDistance, dist)
            if !isUserDragging && dist > Self.dragThreshold {
                isUserDragging = true
                showSnapPreview(at: cursor)
            }
            if isUserDragging {
                let newOrigin = NSPoint(
                    x: dragStartWindowOrigin.x + dx,
                    y: dragStartWindowOrigin.y + dy
                )
                self.setFrameOrigin(newOrigin)
                updateSnapPreview(at: cursor)
                return
            }
            super.sendEvent(event)
        case .leftMouseUp:
            if isUserDragging {
                isUserDragging = false
                snapPreview.hide()
                snapToNearestZone(at: NSEvent.mouseLocation)
                return
            }
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }

    /// Pick the snap zone closest to where the user released. The
    /// cursor's screen is split into 5 equal-width strips, one per
    /// zone. Updates prefs, which fires the observer that animates the
    /// window to its new resting place.
    private func snapToNearestZone(at cursor: NSPoint) {
        let (zone, screen) = nearestSnap(at: cursor)
        if let id = Self.displayID(of: screen) {
            preferences.notchScreenID = id
        }
        preferences.notchPosition = zone
    }

    /// Resolve which (screen, zone) the cursor is currently nearest to.
    /// Used by both the live preview during drag and the final snap.
    private func nearestSnap(at cursor: NSPoint) -> (NotchPosition, NSScreen) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? currentScreen
        let f = screen.frame
        let relX = cursor.x - f.minX
        let bucket = max(0, min(4, Int(relX / (f.width / 5))))
        let zones: [NotchPosition] = [
            .topLeft, .topMidLeft, .topCenter, .topMidRight, .topRight,
        ]
        return (zones[bucket], screen)
    }

    /// Where the pill would land for a given (zone, screen). Mirrors
    /// the math in `collapsedFrame` but for an arbitrary zone, and
    /// uses the actual pill width (not the 560-wide topCenter window)
    /// so the preview matches what the user will visually see.
    private func snapPreviewRect(for position: NotchPosition, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        let pillWidth = lastCollapsedSize.width > 0 ? lastCollapsedSize.width : notchWidth
        let pillHeight = lastCollapsedSize.height > 0 ? lastCollapsedSize.height : notchHeight
        let topGap: CGFloat = (
            position == .topCenter && screen.safeAreaInsets.top > 0
        ) ? 0 : Self.floatingTopGap
        let x: CGFloat
        if position == .topCenter {
            x = f.midX - pillWidth / 2
        } else {
            x = horizontalOrigin(for: position, contentWidth: pillWidth, on: screen)
        }
        return CGRect(x: x, y: f.maxY - pillHeight - topGap, width: pillWidth, height: pillHeight)
    }

    private func showSnapPreview(at cursor: NSPoint) {
        let (zone, screen) = nearestSnap(at: cursor)
        snapPreview.show(at: snapPreviewRect(for: zone, on: screen))
    }

    private func updateSnapPreview(at cursor: NSPoint) {
        let (zone, screen) = nearestSnap(at: cursor)
        snapPreview.move(to: snapPreviewRect(for: zone, on: screen))
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
        // While the panel is expanded the expand animation owns the
        // frame. Bailing here is what stops a SwiftUI re-render that
        // happens to also touch collapsedSize (e.g. showPermissionAlert
        // toggling) from racing the expand and snapping the window
        // back to pill-height.
        if isExpanded { return }
        let target = collapsedFrame(size: size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(target, display: true)
        }
        clickHost.hitShape = .centered(width: size.width)
    }

    private func updateExpanded(_ expanded: Bool) {
        isExpanded = expanded
        let target = expanded ? expandedFrame() : collapsedFrame(size: lastCollapsedSize)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(target, display: true)
        }
        clickHost.hitShape = expanded
            ? .full
            : .centered(width: lastCollapsedSize.width)
    }
}

/// Wraps an `NSHostingView` and filters mouse hit-tests so that clicks
/// on transparent regions of the window fall through to whatever is
/// beneath (the macOS menu bar, in our case). The `NotchWindow` frame
/// is a fixed 560 px strip at the top of the screen to keep the
/// collapsed↔expanded transition from jumping horizontally, but the
/// actual visible pill is much narrower — without this filter, clicks
/// on menu-bar items under the transparent parts of the window would
/// be swallowed (GitHub issue #3).
final class ClickThroughHostingView<Content: View>: NSView {
    enum HitShape {
        /// Window is effectively invisible — ignore everything.
        case none
        /// Expanded panel fills the window — absorb every click.
        case full
        /// Collapsed pill: horizontal strip of the given width,
        /// centered in the window, full current height.
        case centered(width: CGFloat)
    }

    let hosting: NSHostingView<Content>
    var hitShape: HitShape = .none

    init(rootView: Content) {
        self.hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let region: CGRect
        switch hitShape {
        case .none:
            return nil
        case .full:
            region = bounds
        case .centered(let width):
            region = CGRect(
                x: (bounds.width - width) / 2,
                y: 0,
                width: width,
                height: bounds.height
            )
        }
        guard region.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

/// Translucent ghost shown at the live snap target while the user is
/// dragging the notch. Lives at the same window level as `NotchWindow`,
/// ignores all mouse events (so the drag stays uninterrupted), and
/// fades in/out around show/hide.
final class SnapPreviewWindow: NSPanel {
    private let hosting: NSHostingView<SnapPreviewView>

    init() {
        let view = SnapPreviewView()
        let host = NSHostingView(rootView: view)
        self.hosting = host
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .statusBar
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.alphaValue = 0
        host.autoresizingMask = [.width, .height]
        self.contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(at rect: CGRect) {
        self.setFrame(rect, display: true)
        if !self.isVisible {
            self.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    func move(to rect: CGRect) {
        // Animate the frame so zone-to-zone jumps glide instead of
        // teleporting — much easier to read at a glance.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(rect, display: true)
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

private struct SnapPreviewView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 1.5)
            )
    }
}
