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
    /// Horizontal offset the SwiftUI pill is currently rendering at
    /// (used in silhouette mode when left/right slot widths differ).
    /// Click hit-region and hover rect both shift with this so they
    /// track the visible pill instead of its centered default.
    private var lastPillOffsetX: CGFloat = 0
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
    /// Set to true while we're applying multiple prefs writes
    /// atomically (e.g. during a drag release). The Combine observers
    /// skip while this is on so we don't trigger one animation per
    /// pref change — we run a single reposition at the end instead.
    private var suppressPrefsReposition = false

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
            },
            onCollapsedOffsetChange: { [weak self] offset in
                self?.updatePillOffset(offset)
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
        preferences.$notchAnchorFraction
            .dropFirst()
            .sink { [weak self] _ in self?.repositionForCurrentState() }
            .store(in: &prefsCancellables)
        preferences.$notchAnchorYFromTop
            .dropFirst()
            .sink { [weak self] _ in self?.repositionForCurrentState() }
            .store(in: &prefsCancellables)
        preferences.$pinToTopEdge
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

    /// Frame for the collapsed pill. When the user is sitting exactly
    /// on the hardware notch we keep a 560-wide window so the
    /// silhouette flows seamlessly into the cutout (and the click
    /// pass-through layer handles the transparent margins). Anywhere
    /// else the window matches the pill width — smaller footprint, no
    /// pass-through trickery needed.
    private func collapsedFrame(size: CGSize) -> NSRect {
        let screen = currentScreen
        let f = screen.frame
        let topGap = topGapForCurrentState(on: screen)
        if isHardwareNotchAnchored(on: screen) {
            let w: CGFloat = Self.expandedPanelWidth
            return NSRect(
                x: f.midX - w / 2,
                y: f.maxY - size.height - topGap,
                width: w,
                height: size.height
            )
        }
        let x = horizontalOrigin(
            forFraction: preferences.notchAnchorFraction,
            contentWidth: size.width,
            on: screen
        )
        let y = collapsedY(forContentHeight: size.height, on: screen, topGap: topGap)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func expandedFrame() -> NSRect {
        let screen = currentScreen
        let f = screen.frame
        let w: CGFloat = Self.expandedPanelWidth
        let h: CGFloat = Self.expandedPanelHeight
        let topGap = topGapForCurrentState(on: screen)
        let x = horizontalOrigin(
            forFraction: preferences.notchAnchorFraction,
            contentWidth: w,
            on: screen
        )
        // The expanded panel grows downward from wherever the pill is
        // sitting. When pinned to the top edge that's just `f.maxY -
        // h`; when free-positioned, anchor the top of the panel to
        // where the pill currently is and clamp so the panel can't
        // walk off the bottom of the screen.
        let pillY = collapsedY(
            forContentHeight: lastCollapsedSize.height > 0 ? lastCollapsedSize.height : notchHeight,
            on: screen,
            topGap: topGap
        )
        let pillTop = pillY + (lastCollapsedSize.height > 0 ? lastCollapsedSize.height : notchHeight)
        var panelY = pillTop - h
        panelY = max(f.minY, panelY)
        return NSRect(x: x, y: panelY, width: w, height: h)
    }

    /// Y of the collapsed pill in screen coords (AppKit, bottom-left
    /// origin). Honors `pinToTopEdge` — when false we use the saved
    /// `notchAnchorYFromTop` and clamp so the pill stays on screen.
    private func collapsedY(
        forContentHeight contentHeight: CGFloat,
        on screen: NSScreen,
        topGap: CGFloat
    ) -> CGFloat {
        let f = screen.frame
        if preferences.pinToTopEdge {
            return f.maxY - contentHeight - topGap
        }
        let yFromTop = preferences.notchAnchorYFromTop
        let pillTop = f.maxY - yFromTop
        let minY = f.minY  // pill bottom can't go below screen
        let maxY = f.maxY - contentHeight  // pill top can't go above screen top
        return min(max(pillTop - contentHeight, minY), maxY)
    }

    /// Convert a 0…1 anchor fraction into the window's left edge in
    /// screen coords for content of the given width. We clamp so the
    /// content never falls off either edge of the screen — important
    /// for the 560-wide expanded panel on narrow displays.
    private func horizontalOrigin(
        forFraction fraction: CGFloat,
        contentWidth: CGFloat,
        on screen: NSScreen
    ) -> CGFloat {
        let f = screen.frame
        let minX = f.minX + Self.edgePadding
        let maxX = f.maxX - contentWidth - Self.edgePadding
        let placeableRange = max(0, maxX - minX)
        let clamped = min(max(fraction, 0), 1)
        return minX + clamped * placeableRange
    }

    /// True when the user has the pill anchored exactly at top-center
    /// on a screen with a hardware notch — the only configuration in
    /// which we render the notch silhouette and skip the top breathing
    /// gap. Free-positioning mode (`pinToTopEdge = false`) disqualifies
    /// silhouette since the pill could be anywhere on the screen.
    private func isHardwareNotchAnchored(on screen: NSScreen) -> Bool {
        guard preferences.pinToTopEdge else { return false }
        guard screen.safeAreaInsets.top > 0 else { return false }
        return abs(preferences.notchAnchorFraction - 0.5) < 0.001
    }

    /// Floating positions get a small gap from the top of the screen.
    /// The hardware-notch anchor stays flush so the pill keeps flowing
    /// seamlessly out of the cutout.
    private func topGapForCurrentState(on screen: NSScreen) -> CGFloat {
        isHardwareNotchAnchored(on: screen) ? 0 : Self.floatingTopGap
    }

    /// Pulls the CG display ID off an NSScreen. Used to remember which
    /// physical display the user pinned the notch to.
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return screen.deviceDescription[key] as? CGDirectDisplayID
    }

    /// The pill's actual rect on screen — used by `MouseMonitor` to size
    /// the hover hit area. In `topCenter` the pill is narrower than the
    /// 560-wide window (centered inside it, plus any silhouette offset);
    /// in every other zone the window already matches the pill, so we
    /// just use the window left edge.
    var currentPillRect: CGRect {
        let f = self.frame
        let h = lastCollapsedSize.height > 0 ? lastCollapsedSize.height : notchHeight
        let pillWidth = lastCollapsedSize.width > 0 ? lastCollapsedSize.width : notchWidth
        let x: CGFloat
        if isHardwareNotchAnchored(on: currentScreen) {
            x = f.midX - pillWidth / 2 + lastPillOffsetX
        } else {
            x = f.minX
        }
        return CGRect(x: x, y: f.maxY - h, width: pillWidth, height: h)
    }

    /// Recompute and apply the right frame for the current state.
    /// Called from prefs / screen-change observers.
    private func repositionForCurrentState() {
        guard !isUserDragging else { return }
        guard !suppressPrefsReposition else { return }
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
                snapToReleaseLocation()
                return
            }
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }

    /// Distance (in points) within which the pill snaps to a magnet
    /// anchor. Outside this radius the user's drop location is
    /// honored verbatim — free positioning anywhere along the top.
    private static let snapMagnetRadius: CGFloat = 80

    /// Compute where the pill currently sits in fractional terms
    /// (based on the actual window frame), then either magnetize to
    /// one of {0.0, 0.5, 1.0} when close enough or honor the drop
    /// location. When `pinToTopEdge` is off, also persist the
    /// vertical drop position so the pill stays where the user left
    /// it on the next launch.
    private func snapToReleaseLocation() {
        let frame = self.frame
        let pillCenter = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pillCenter) })
            ?? currentScreen
        let f = screen.frame
        let pillWidth = lastCollapsedSize.width > 0 ? lastCollapsedSize.width : frame.width
        let minPillCenter = f.minX + Self.edgePadding + pillWidth / 2
        let maxPillCenter = f.maxX - Self.edgePadding - pillWidth / 2
        let range = max(1, maxPillCenter - minPillCenter)
        let rawFraction = (frame.midX - minPillCenter) / range
        var snapped = min(max(rawFraction, 0), 1)

        // Magnetic snap — only when pinned to the top edge. In free
        // mode the user wants the pill exactly where they dropped it,
        // not pulled toward an anchor.
        if preferences.pinToTopEdge {
            var bestDistance: CGFloat = .greatestFiniteMagnitude
            for anchor in NotchSnapAnchor.allCases {
                let anchorCenter = minPillCenter + anchor.fraction * range
                let distance = abs(frame.midX - anchorCenter)
                if distance < Self.snapMagnetRadius && distance < bestDistance {
                    bestDistance = distance
                    snapped = anchor.fraction
                }
            }
        }

        // Apply all prefs in a single batch so only one reposition
        // fires at the end — otherwise the pill briefly animates to
        // wherever (old yFromTop, new fraction) lands before the
        // second observer correction comes in.
        suppressPrefsReposition = true
        if let id = Self.displayID(of: screen) {
            preferences.notchScreenID = id
        }
        if !preferences.pinToTopEdge {
            let pillTop = frame.origin.y + frame.height
            let yFromTop = max(0, f.maxY - pillTop)
            preferences.notchAnchorYFromTop = yFromTop
        }
        preferences.notchAnchorFraction = snapped
        suppressPrefsReposition = false
        repositionForCurrentState()
    }

    /// Where the pill would land for a given fraction on a screen.
    /// Used by the live snap preview while dragging.
    private func snapPreviewRect(forFraction fraction: CGFloat, on screen: NSScreen) -> CGRect {
        let f = screen.frame
        let pillWidth = lastCollapsedSize.width > 0 ? lastCollapsedSize.width : notchWidth
        let pillHeight = lastCollapsedSize.height > 0 ? lastCollapsedSize.height : notchHeight
        let isCenterMagnet = abs(fraction - 0.5) < 0.001
        let topGap: CGFloat = (isCenterMagnet && screen.safeAreaInsets.top > 0)
            ? 0 : Self.floatingTopGap
        let x = horizontalOrigin(forFraction: fraction, contentWidth: pillWidth, on: screen)
        return CGRect(x: x, y: f.maxY - pillHeight - topGap, width: pillWidth, height: pillHeight)
    }

    /// Returns the magnet anchor + screen the cursor is currently
    /// hovering near, or `nil` if it's outside every magnet's pull
    /// radius. Used to decide whether to draw the snap preview. When
    /// the user has free positioning enabled (`pinToTopEdge = false`),
    /// the magnets are disabled entirely.
    private func nearestMagnet(at cursor: NSPoint) -> (CGFloat, NSScreen)? {
        guard preferences.pinToTopEdge else { return nil }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? currentScreen
        let f = screen.frame
        let pillWidth = lastCollapsedSize.width > 0 ? lastCollapsedSize.width : notchWidth
        let minPillCenter = f.minX + Self.edgePadding + pillWidth / 2
        let maxPillCenter = f.maxX - Self.edgePadding - pillWidth / 2
        let range = max(1, maxPillCenter - minPillCenter)
        var bestAnchor: CGFloat?
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        for anchor in NotchSnapAnchor.allCases {
            let anchorCenter = minPillCenter + anchor.fraction * range
            let distance = abs(cursor.x - anchorCenter)
            if distance < Self.snapMagnetRadius && distance < bestDistance {
                bestDistance = distance
                bestAnchor = anchor.fraction
            }
        }
        guard let anchor = bestAnchor else { return nil }
        return (anchor, screen)
    }

    /// Where the pill will land if released right now and how to
    /// style the preview. Magnet rect + `.magnetActive` if the cursor
    /// is in a magnet's pull radius (only while pinned to the top
    /// edge), otherwise a free-drop rect that mirrors the pill's
    /// current x and — when pinned — projects to the top edge.
    private func snapPreviewTarget(at cursor: NSPoint) -> (CGRect, SnapPreviewWindow.Style) {
        if let (fraction, screen) = nearestMagnet(at: cursor) {
            return (snapPreviewRect(forFraction: fraction, on: screen), .magnetActive)
        }
        let pillCenterX = self.frame.midX
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: pillCenterX, y: self.frame.midY))
        })
            ?? NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? currentScreen
        let f = screen.frame
        let pillWidth = lastCollapsedSize.width > 0 ? lastCollapsedSize.width : notchWidth
        let pillHeight = lastCollapsedSize.height > 0 ? lastCollapsedSize.height : notchHeight
        let minPillCenter = f.minX + Self.edgePadding + pillWidth / 2
        let maxPillCenter = f.maxX - Self.edgePadding - pillWidth / 2
        let clampedCenter = min(max(pillCenterX, minPillCenter), maxPillCenter)
        let landingX = clampedCenter - pillWidth / 2
        let landingY: CGFloat
        if preferences.pinToTopEdge {
            // Always show where it'll snap up to on the top edge.
            landingY = f.maxY - pillHeight - Self.floatingTopGap
        } else {
            // Free positioning: the pill's top edge lands at the
            // dragged window's top edge (matches what
            // snapToReleaseLocation saves), so the preview's top has
            // to align with the window's top — not the window's
            // bottom, which would push the ghost below the pill area
            // when dragging while expanded.
            let windowTop = self.frame.origin.y + self.frame.height
            let raw = windowTop - pillHeight
            landingY = min(max(raw, f.minY), f.maxY - pillHeight)
        }
        let rect = CGRect(x: landingX, y: landingY, width: pillWidth, height: pillHeight)
        return (rect, .freeDrop)
    }

    private func showSnapPreview(at cursor: NSPoint) {
        let (target, style) = snapPreviewTarget(at: cursor)
        snapPreview.show(at: target, style: style)
    }

    private func updateSnapPreview(at cursor: NSPoint) {
        let (target, style) = snapPreviewTarget(at: cursor)
        if snapPreview.isVisible {
            snapPreview.move(to: target, style: style)
        } else {
            snapPreview.show(at: target, style: style)
        }
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
        clickHost.hitShape = .centered(width: size.width, offsetX: lastPillOffsetX)
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
            : .centered(width: lastCollapsedSize.width, offsetX: lastPillOffsetX)
    }

    /// Track the SwiftUI pill's horizontal offset so the click hit
    /// region and hover anchor follow whatever silhouette-alignment
    /// shift the content view is applying.
    private func updatePillOffset(_ offset: CGFloat) {
        guard offset != lastPillOffsetX else { return }
        lastPillOffsetX = offset
        if !isExpanded {
            clickHost.hitShape = .centered(
                width: lastCollapsedSize.width,
                offsetX: offset
            )
        }
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
        /// centered in the window plus an optional `offsetX` so the
        /// hit region tracks the pill when SwiftUI shifts it (e.g.
        /// silhouette mode with asymmetric slot widths).
        case centered(width: CGFloat, offsetX: CGFloat = 0)
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
        case .centered(let width, let offsetX):
            region = CGRect(
                x: (bounds.width - width) / 2 + offsetX,
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
/// fades in/out around show/hide. Has two visual states — a subtle
/// free-drop look and a more prominent "magnet locked" look so the
/// user can tell at a glance whether they're about to snap.
final class SnapPreviewWindow: NSPanel {
    enum Style {
        case freeDrop
        case magnetActive
    }

    private let hosting: NSHostingView<SnapPreviewView>
    private var currentStyle: Style = .freeDrop

    init() {
        let view = SnapPreviewView(style: .freeDrop)
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

    func show(at rect: CGRect, style: Style) {
        applyStyle(style)
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

    func move(to rect: CGRect, style: Style) {
        applyStyle(style)
        // No animation — the user is dragging in real time and any
        // smoothing reads as input lag.
        self.setFrame(rect, display: true)
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    private func applyStyle(_ style: Style) {
        guard style != currentStyle else { return }
        currentStyle = style
        hosting.rootView = SnapPreviewView(style: style)
    }
}

private struct SnapPreviewView: View {
    let style: SnapPreviewWindow.Style

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(fillOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: strokeWidth)
            )
    }

    private var fillOpacity: Double {
        style == .magnetActive ? 0.28 : 0.10
    }
    private var strokeOpacity: Double {
        style == .magnetActive ? 0.85 : 0.40
    }
    private var strokeWidth: CGFloat {
        style == .magnetActive ? 2.0 : 1.0
    }
}
