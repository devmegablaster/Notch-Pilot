import SwiftUI
import AppKit

struct NotchContentView: View {
    @ObservedObject var monitor: ClaudeMonitor
    @ObservedObject var hookBridge: HookBridge
    @ObservedObject var heatmap: HeatmapAggregator
    @ObservedObject var usage: UsageAggregator
    @ObservedObject var mouseMonitor: MouseMonitor
    @ObservedObject var speechController: SpeechController
    @ObservedObject var updateChecker: UpdateChecker
    @EnvironmentObject var prefs: BuddyPreferences
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    // Callbacks up to the owning NSPanel so it can resize/show in sync
    // with the view's logical state.
    var onVisibilityChange: (Bool) -> Void
    var onCollapsedSizeChange: (CGSize) -> Void
    var onExpandedChange: (Bool) -> Void

    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?

    /// Set true while the buddy is doing an "idle peek" — a brief
    /// random eye-open while pinned in always-visible mode.
    @State private var idlePeekActive = false
    @State private var idlePeekTask: Task<Void, Never>?

    /// Currently hovered heatmap cell (0-23) or nil. Drives the
    /// header tooltip + cell highlight.
    @State private var hoveredHeatmapHour: Int?

    /// Session being inspected in the detail overlay (or nil). Set by
    /// clicking a row in the session list; cleared by dismissing the
    /// overlay. Keeps the panel open while non-nil.
    @State private var inspectedSession: ClaudeSession?
    // Synchronously-controlled visibility. Set to true the moment activity
    // appears; only set back to false after the fade-out delay elapses with
    // no fresh activity. Decoupled from `hasAnyActivity` so we don't race
    // against SwiftUI's body-then-onChange evaluation order.
    @State private var displayedVisible = false
    @State private var fadeOutToken = UUID()
    @State private var filterQuery: String = ""
    @State private var showingAppearancePicker = false
    /// The most recent session we've seen actively working. Captured
    /// on every monitor tick while an active session exists, so when
    /// the claude process exits and the session drops out of
    /// `monitor.sessions` entirely we can still look up which one it
    /// was for the session-finished speech.
    @State private var lastSeenActiveSession: ClaudeSession?

    /// IDs of sessions currently in the "active" state (non-empty
    /// shortStatus). Used to detect per-session transitions from
    /// active → inactive so we can fire a speech for every session
    /// that completes, not just when all sessions are idle.
    @State private var activeSessionIDs: Set<String> = []

    /// Snapshot of sessions from the previous monitor tick. When the
    /// set of active IDs shrinks, we look up the finished session here
    /// to grab its project name (since the session may have already
    /// dropped out of `monitor.sessions` in the newer snapshot).
    @State private var previousSessions: [String: ClaudeSession] = [:]

    private let fadeOutDuration: TimeInterval = 10

    private let leftSectionWidth: CGFloat = 56
    private let rightPillHorizontalPadding: CGFloat = 14
    private let rightPillMinWidth: CGFloat = 70
    private let rightPillMaxWidth: CGFloat = 220

    private let expandedWidth: CGFloat = 560
    private let expandedHeight: CGFloat = 440

    // MARK: - Derived state

    private var workingSession: ClaudeSession? {
        monitor.sessions.first(where: { !$0.shortStatus.isEmpty })
    }

    private var activeCount: Int {
        monitor.sessions.filter { !$0.shortStatus.isEmpty }.count
    }

    private var hasAnyActivity: Bool {
        activeCount > 0 || hookBridge.pendingPermission != nil
    }

    private var shouldShow: Bool {
        // Shown when ANY of:
        //   - Claude is actively working / in the 10s fadeout window
        //   - The user is hovering over the notch area (summon-on-hover)
        //   - The expanded panel is open (the user is actively using it —
        //     don't rip it out from under them just because the cursor
        //     moved out of the notch hit rect into the panel body)
        //   - The appearance picker overlay is open
        prefs.alwaysVisible
            || displayedVisible
            || mouseMonitor.isHoveringNotch
            || expanded
            || showingAppearancePicker
            || inspectedSession != nil
            || speechController.current != nil
            || usageDetailShown
    }

    /// True while the buddy is doing a speech pop-out. Drives the
    /// collapsed-view mode swap and the window frame's height.
    private var isSpeaking: Bool {
        speechController.current != nil
    }

    /// Extra vertical space added to the pill while the buddy is
    /// speaking, to fit a title+subtitle row below the notch area.
    private let speechExtraHeight: CGFloat = 44

    private var speechPillHeight: CGFloat {
        notchHeight + speechExtraHeight
    }

    private var collapsedSize: CGSize {
        if isSpeaking {
            return CGSize(width: collapsedWidth, height: speechPillHeight)
        }
        return CGSize(width: collapsedWidth, height: notchHeight)
    }

    private var hasPendingPermission: Bool {
        hookBridge.pendingPermission != nil
    }

    private var effectivelyExpanded: Bool {
        expanded || hasPendingPermission
    }

    private var mode: BuddyFace.Mode {
        if hasPendingPermission { return .curious }

        // Reactive: pick a mode based on what Claude is currently doing.
        if let working = workingSession {
            switch working.toolAction {
            case .danger:  return .shocked
            case .editing: return .focused
            case .shell,
                 .reading,
                 .web,
                 .delegating,
                 .planning,
                 .thinking,
                 .none:
                return .active
            }
        }

        if displayedVisible { return .content }  // "all done" glow
        if mouseMonitor.isHoveringNotch { return .idle }  // hover summon
        if idlePeekActive { return .idle }                // random "peek"
        return .sleeping
    }

    /// Accent color sourced from the user's picked buddy color. Every
    /// orange-ish UI element in the panel (buttons, badges, active dots,
    /// etc.) reads from `accent` so the whole app themes to the buddy.
    private var accent: Color { prefs.color.base }
    private var accentDim: Color { prefs.color.base.opacity(0.18) }
    private var accentBorder: Color { prefs.color.base.opacity(0.5) }

    private var currentStatus: String {
        if activeCount > 0 {
            return activeCount == 1 ? "1 session" : "\(activeCount) sessions"
        }
        if displayedVisible {
            return "all done"
        }
        if mouseMonitor.isHoveringNotch {
            return "hi"
        }
        // Pinned-but-idle: simple "zzz…" so the buddy doesn't look
        // frozen on always-visible mode.
        if prefs.alwaysVisible && !hasAnyActivity {
            return "zzz…"
        }
        return ""
    }

    /// True when the right-side status text is in an idle/snoozing
    /// state — used to render it in subdued grey instead of white.
    private var isIdleStatus: Bool {
        activeCount == 0
            && !mouseMonitor.isHoveringNotch
            && !displayedVisible
    }

    private var rightSectionWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let measured = (currentStatus as NSString)
            .size(withAttributes: [.font: font]).width
        let total = measured + rightPillHorizontalPadding * 2
        return min(max(total, rightPillMinWidth), rightPillMaxWidth)
    }

    private var collapsedWidth: CGFloat {
        leftSectionWidth + notchWidth + rightSectionWidth
    }

    /// Anchor point for the collapsed pill's open/close scale transition,
    /// expressed in the pill's own unit coordinate space. Points at the
    /// top edge of the pill right where the physical notch lives, so the
    /// pill looks like it's emerging from / retracting into the notch.
    private var collapsedNotchAnchor: UnitPoint {
        let notchCenterX = leftSectionWidth + notchWidth / 2
        let x = collapsedWidth > 0 ? notchCenterX / collapsedWidth : 0.5
        return UnitPoint(x: x, y: 0)
    }

    /// Anchor for the expanded panel's open/close scale transition.
    /// The expanded panel is centered on the notch horizontally, so
    /// 0.5 is exactly right.
    private let expandedNotchAnchor = UnitPoint(x: 0.5, y: 0)

    // MARK: - Body

    var body: some View {
        Group {
            if shouldShow {
                if hasPendingPermission, let permission = hookBridge.pendingPermission {
                    permissionPanel(permission)
                        .transition(
                            .scale(scale: 0.04, anchor: expandedNotchAnchor)
                            .combined(with: .opacity)
                        )
                } else if expanded {
                    expandedPanel
                        .transition(
                            .scale(scale: 0.04, anchor: expandedNotchAnchor)
                            .combined(with: .opacity)
                        )
                } else if let speech = speechController.current {
                    speechPill(speech)
                        .transition(
                            .scale(scale: 0.15, anchor: collapsedNotchAnchor)
                            .combined(with: .opacity)
                        )
                } else {
                    collapsedPill
                        // Scale toward the notch (where the physical
                        // cutout lives — not the pill's geometric
                        // center, which is offset when the right-side
                        // text pill is wider than the left eye).
                        .transition(
                            .scale(scale: 0.04, anchor: collapsedNotchAnchor)
                            .combined(with: .opacity)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: effectivelyExpanded)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: shouldShow)
        // Animate the branch swap between collapsedPill and speechPill
        // so the pop-out scales in/out smoothly instead of just
        // replacing the view. Keyed on the speech identity so every
        // distinct speech retriggers the transition.
        .animation(
            .spring(response: 0.5, dampingFraction: 0.72),
            value: speechController.current?.id
        )
        .onChange(of: hasAnyActivity, initial: true) { _, isActive in
            if isActive {
                // Activity present — show immediately and invalidate any
                // pending fade-out task.
                displayedVisible = true
                fadeOutToken = UUID()
            } else {
                // Schedule a fade-out. Capture a fresh token so that if a
                // newer activity → fade-out cycle starts, this stale task
                // becomes a no-op when it wakes.
                let token = UUID()
                fadeOutToken = token
                Task { @MainActor in
                    try? await Task.sleep(
                        nanoseconds: UInt64(fadeOutDuration * 1_000_000_000)
                    )
                    guard fadeOutToken == token, !hasAnyActivity else { return }
                    displayedVisible = false
                }
            }
        }
        .onChange(of: shouldShow, initial: true) { _, newValue in
            onVisibilityChange(newValue)
            if newValue {
                // Re-push the current size in case the window was collapsed
                // while invisible — onAppear only fires once.
                onCollapsedSizeChange(collapsedSize)
            } else {
                expanded = false
            }
        }
        .onChange(of: effectivelyExpanded) { _, newValue in
            onExpandedChange(newValue)
            // Haptic tick on panel open/close. This is the canonical
            // "the notch just did something" state — fires on hover,
            // un-hover, permission arrival, permission resolved. Uses
            // `.levelChange` (most pronounced of the three patterns)
            // with `.drawCompleted` so the tick lands exactly when
            // the frame change becomes visible.
            if prefs.hapticsEnabled {
                NSHapticFeedbackManager.defaultPerformer.perform(
                    .levelChange,
                    performanceTime: .drawCompleted
                )
            }
        }
        .onChange(of: collapsedSize) { _, newSize in
            onCollapsedSizeChange(newSize)
        }
        .onChange(of: hookBridge.pendingPermission?.id) { oldID, newID in
            if oldID != nil && newID == nil {
                expanded = false
            }
            if let p = hookBridge.pendingPermission, newID != oldID {
                VoiceAnnouncer.shared.speak(
                    "Claude needs permission for \(p.toolName) in \(p.projectName)",
                    event: .permission,
                    prefs: prefs
                )
            }
        }
        .onChange(of: monitor.sessions, initial: true) { _, newSessions in
            // Dismiss permission prompts that the user answered in
            // the terminal — detected when the session's jsonl shows
            // new activity after the permission was queued.
            hookBridge.dismissStalePermissions(sessions: newSessions)

            // Build the new set of active session IDs.
            let nowActive = Set(
                newSessions.filter { !$0.shortStatus.isEmpty }.map(\.id)
            )

            // Detect per-session active → inactive transitions. This
            // is the key — each individual session completion fires a
            // speech, not only when everything goes idle. Look the
            // finished session up from either the current snapshot OR
            // the previous one (in case it dropped out entirely).
            let justFinished = activeSessionIDs.subtracting(nowActive)
            for finishedID in justFinished {
                let session = newSessions.first(where: { $0.id == finishedID })
                    ?? previousSessions[finishedID]
                    ?? lastSeenActiveSession
                if prefs.speechAllows(.sessionFinished), let s = session {
                    speechController.speak(
                        kind: .sessionFinished,
                        // Minute-bucketed key so back-to-back completions
                        // on the same session (rare but possible) don't
                        // all dedup into a single speech.
                        key: "sess-\(finishedID)-\(Int(Date().timeIntervalSince1970 / 60))",
                        title: s.projectName,
                        subtitle: "done",
                        icon: "checkmark.circle.fill",
                        tint: .accent
                    )
                }
            }

            activeSessionIDs = nowActive

            // Rebuild the session-ID → session lookup for the next tick.
            var snapshot: [String: ClaudeSession] = [:]
            for s in newSessions { snapshot[s.id] = s }
            previousSessions = snapshot

            // Also maintain lastSeenActiveSession as a last-resort fallback.
            if let active = newSessions.first(where: { !$0.shortStatus.isEmpty }) {
                lastSeenActiveSession = active
            } else if let mostRecent = newSessions.max(
                by: { $0.lastActivity < $1.lastActivity }
            ) {
                lastSeenActiveSession = mostRecent
            }
        }
        .onChange(of: workingSession?.toolAction) { oldAction, newAction in
            if newAction == .danger && oldAction != .danger {
                VoiceAnnouncer.shared.speak(
                    "Dangerous command detected",
                    event: .danger,
                    prefs: prefs
                )
            }
        }
        .onChange(of: hasAnyActivity) { oldValue, newValue in
            if oldValue == true && newValue == false {
                // Voice announcer only — the buddy speech bubble is
                // fired per-session from the monitor.sessions onChange
                // above, not here. This block is just for the "all
                // done" voice cue when everything goes idle.
                VoiceAnnouncer.shared.speak(
                    "Claude finished",
                    event: .finished,
                    prefs: prefs
                )
            } else if oldValue == false && newValue == true {
                VoiceAnnouncer.shared.speak(
                    "Claude is working",
                    event: .started,
                    prefs: prefs
                )
            }
        }
        .onAppear {
            onCollapsedSizeChange(collapsedSize)
            startIdlePeekLoop()
        }
    }

    // MARK: - Idle peek loop

    /// Background loop that — only when always-visible is on and the
    /// app is fully idle — periodically opens the buddy's eyes for a
    /// brief "peek", swaps in a new idle message, then closes them
    /// again. Random gaps so it doesn't feel mechanical.
    private func startIdlePeekLoop() {
        idlePeekTask?.cancel()
        idlePeekTask = Task { @MainActor in
            // Wait a bit on launch so the loop doesn't fire while the
            // onboarding intro is still playing.
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                let waitMs = UInt64.random(in: 28_000 ... 75_000)
                try? await Task.sleep(for: .milliseconds(Int(waitMs)))
                if Task.isCancelled { return }

                // Only peek when always-visible is on AND nothing else
                // is going on — no active session, no permission, not
                // already shown via hover or expansion.
                let canPeek = prefs.alwaysVisible
                    && !hasAnyActivity
                    && !hasPendingPermission
                    && !mouseMonitor.isHoveringNotch
                    && !expanded
                guard canPeek else { continue }

                withAnimation(.easeOut(duration: 0.45)) {
                    idlePeekActive = true
                }

                // Hold the peek for ~1.6s so it reads.
                try? await Task.sleep(for: .milliseconds(1600))
                if Task.isCancelled { return }

                withAnimation(.easeIn(duration: 0.4)) {
                    idlePeekActive = false
                }
            }
        }
    }

    // MARK: - Speech pill

    /// The "buddy popping out of the notch to say something" view.
    /// Same horizontal footprint as the collapsed pill so the notch
    /// cutout stays in the exact same place — only the vertical axis
    /// grows. The buddy moves from its usual left-of-notch spot to
    /// the center of the notch, and a title + subtitle drop in below.
    private func speechPill(_ speech: BuddySpeech) -> some View {
        let w = collapsedWidth
        let h = speechPillHeight
        let cornerRadius = notchHeight * 0.55
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
        let tint: Color = {
            switch speech.tint {
            case .accent:  return accent
            case .danger:  return Color(red: 0.97, green: 0.56, blue: 0.56)
            case .neutral: return .white.opacity(0.7)
            }
        }()

        // Offset the lower text block so it sits centered under the
        // physical notch, not the geometric center of the pill.
        let notchCenterX = leftSectionWidth + notchWidth / 2
        let textOffsetX = notchCenterX - w / 2

        return VStack(spacing: 5) {
            // Top row: same 3-section layout as the collapsed pill,
            // but the buddy lives INSIDE the notch section instead
            // of on the right edge of the left section.
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: leftSectionWidth, height: notchHeight)

                BuddyFace(mode: .content, size: 10)
                    .frame(width: notchWidth, height: notchHeight)

                Color.clear
                    .frame(width: rightSectionWidth, height: notchHeight)
            }

            // Below: project name + status word, centered under the
            // notch by offsetting the whole text block horizontally.
            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: speech.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(tint)
                    Text(speech.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(speech.subtitle)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(tint.opacity(0.85))
                    .lineLimit(1)
            }
            .offset(x: textOffsetX)

            Spacer(minLength: 0)
        }
        .frame(width: w, height: h, alignment: .top)
        .background(shape.fill(Color.black))
        .contentShape(shape)
        .contextMenu {
            Button("Quit Notch Pilot") { NSApp.terminate(nil) }
        }
    }

    // MARK: - Collapsed pill

    private var collapsedPill: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: notchHeight * 0.55,
            bottomTrailingRadius: notchHeight * 0.55,
            topTrailingRadius: 0,
            style: .continuous
        )

        return HStack(spacing: 0) {
            // Left section: eyes anchored to the right edge (next to notch)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                BuddyFace(mode: mode, size: 9)
                    .padding(.trailing, 16)
            }
            .frame(width: leftSectionWidth, height: notchHeight)

            // Middle: empty space where the physical notch lives
            Color.clear
                .frame(width: notchWidth, height: notchHeight)

            // Right section: status text anchored to the left edge.
            // Dim to a subdued grey when the notch is idle ("zzz…")
            // so it doesn't scream for attention; bright white while
            // there's actual activity.
            HStack(spacing: 0) {
                Text(currentStatus)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(
                        isIdleStatus
                            ? .white.opacity(0.35)
                            : .white.opacity(0.92)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, rightPillHorizontalPadding)
                Spacer(minLength: 0)
            }
            .frame(width: rightSectionWidth, height: notchHeight)
        }
        .frame(width: collapsedWidth, height: notchHeight, alignment: .topLeading)
        .background(shape.fill(Color.black))
        .contentShape(shape)
        .onHover { hovering in
            if hovering {
                // Cancel any pending collapse — the user came back before
                // the debounce fired, so stay shown.
                collapseTask?.cancel()
                collapseTask = nil
                expanded = true
            }
        }
        .contextMenu {
            Button("Quit Notch Pilot") { NSApp.terminate(nil) }
        }
    }

    // MARK: - Expanded panel

    private var expandedPanel: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 28,
            bottomTrailingRadius: 28,
            topTrailingRadius: 0,
            style: .continuous
        )

        return VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, max(notchHeight, 14) + 10)
                .padding(.horizontal, 22)

            if updateChecker.nodeMissing && !updateChecker.nodeBannerDismissed {
                nodeMissingBanner
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
            }

            filterBar
                .padding(.horizontal, 22)
                .padding(.top, 12)

            divider
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    sessionsSection
                    heatmapSection
                    alwaysAllowedSection
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .onAppear { heatmap.refreshIfNeeded() }
        }
        .frame(width: expandedWidth, height: expandedHeight, alignment: .top)
        .background(shape.fill(Color.black))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
        .overlay(alignment: .top) {
            if showingAppearancePicker {
                appearancePickerOverlay
                    .transition(
                        .scale(scale: 0.96, anchor: .top)
                        .combined(with: .opacity)
                    )
            }
        }
        .overlay(alignment: .top) {
            if let session = inspectedSession {
                sessionDetailOverlay(session)
                    .transition(
                        .scale(scale: 0.96, anchor: .top)
                        .combined(with: .opacity)
                    )
            }
        }
        .overlay(alignment: .top) {
            // Usage detail popover hoisted to the panel-level overlay
            // so it draws above the session list in z-order. Tapping
            // outside the card dismisses (backdrop) — the card itself
            // swallows taps via its own onTapGesture.
            if usageDetailShown {
                ZStack(alignment: .top) {
                    // Explicit Rectangle sized to the panel so the
                    // tap-to-dismiss hit area covers everything that
                    // isn't the popover card.
                    Rectangle()
                        .fill(Color.black.opacity(0.4))
                        .frame(width: expandedWidth, height: expandedHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { usageDetailShown = false }
                    usageDetailPopover
                        .padding(.top, max(notchHeight, 14) + 52)
                        .transition(
                            .opacity
                            .combined(with: .scale(scale: 0.94, anchor: .top))
                        )
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: showingAppearancePicker)
        .animation(.easeOut(duration: 0.18), value: inspectedSession?.id)
        .animation(.easeOut(duration: 0.15), value: usageDetailShown)
        .contentShape(shape)
        .onHover { hovering in
            // Don't collapse while the picker overlay is up — the user may
            // be moving the mouse toward a swatch that's offset from the
            // header and onHover fires a false positive.
            if hovering {
                // Cursor came back — cancel any pending collapse.
                collapseTask?.cancel()
                collapseTask = nil
                return
            }
            guard !showingAppearancePicker
                    && inspectedSession == nil
                    && !usageDetailShown
            else { return }

            // Debounce the collapse. At the edge of the panel's rounded
            // shape the hover state can flip in/out as the window resizes
            // between collapsed and expanded, which produced a rapid
            // flicker loop. Waiting 220ms before actually collapsing
            // lets transient "not hovering" reports settle.
            collapseTask?.cancel()
            collapseTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                if Task.isCancelled { return }
                expanded = false
            }
        }
        .onChange(of: expanded) { _, isExpanded in
            // Closing the panel closes the picker too.
            if !isExpanded {
                showingAppearancePicker = false
                inspectedSession = nil
            }
        }
        .contextMenu {
            Button("Quit Notch Pilot") { NSApp.terminate(nil) }
        }
    }

    // MARK: - Appearance picker overlay

    private var appearancePickerOverlay: some View {
        ZStack(alignment: .top) {
            // Full-panel tap target — any click outside the card dismisses
            // the picker. Must be a Rectangle with an explicit contentShape
            // so SwiftUI hit-tests the whole area, not just visible pixels.
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .contentShape(Rectangle())
                .onTapGesture { showingAppearancePicker = false }

            // Card on top. `.onTapGesture {}` swallows clicks so they
            // don't fall through to the dismissal rectangle underneath.
            VStack(spacing: 0) {
                appearancePickerHeader
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 4)

                ScrollView(showsIndicators: false) {
                    appearancePickerContent
                        .padding(.horizontal, 18)
                        .padding(.bottom, 16)
                        .padding(.top, 6)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 10)
            )
            .frame(maxHeight: expandedHeight - 120)
            .padding(.horizontal, 28)
            .padding(.top, max(notchHeight, 14) + 26)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture { /* swallow */ }
        }
        .frame(width: expandedWidth, height: expandedHeight, alignment: .top)
    }

    // MARK: - Session detail overlay

    private func sessionDetailOverlay(_ session: ClaudeSession) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .contentShape(Rectangle())
                .onTapGesture { inspectedSession = nil }

            VStack(spacing: 0) {
                sessionDetailHeader(session)
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.horizontal, 18)

                ScrollView(showsIndicators: false) {
                    sessionDetailTimeline(session)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 10)
            )
            .frame(maxHeight: expandedHeight - 100)
            .padding(.horizontal, 24)
            .padding(.top, max(notchHeight, 14) + 22)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture { /* swallow */ }
        }
        .frame(width: expandedWidth, height: expandedHeight, alignment: .top)
    }

    private func sessionDetailHeader(_ s: ClaudeSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(s.shortStatus.isEmpty ? Color.white.opacity(0.3) : accent)
                        .frame(width: 7, height: 7)
                    Text(s.projectName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    if !s.shortStatus.isEmpty {
                        Text(s.shortStatus)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(accentDim))
                    }
                }
                HStack(spacing: 6) {
                    if !s.model.isEmpty {
                        Text(compactModelName(s.model))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                        Circle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 2, height: 2)
                    }
                    Text("up \(durationLabel(s.startTime))")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 2, height: 2)
                    Text(relativeTime(s.lastActivity))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                }
                if !s.cwd.isEmpty {
                    Text(s.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            Button {
                if !s.cwd.isEmpty { TerminalJumper.jump(toCwd: s.cwd) }
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("Jump to terminal")

            Button { inspectedSession = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func sessionDetailTimeline(_ s: ClaudeSession) -> some View {
        let events = monitor.recentEvents(for: s, limit: 30)
        if events.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.25))
                Text("No activity yet")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(events) { event in
                    sessionEventRow(event)
                }
            }
        }
    }

    private func sessionEventRow(_ event: SessionEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(eventIconColor(event))
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(eventIconBackground(event))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(eventLabelColor(event))
                    Spacer(minLength: 0)
                    Text(relativeTime(event.timestamp))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.white.opacity(0.35))
                        .monospacedDigit()
                }
                if !event.body.isEmpty {
                    Text(event.body)
                        .font(.system(
                            size: 11,
                            design: event.kind == .toolUse || event.kind == .toolResult
                                ? .monospaced : .default
                        ))
                        .foregroundColor(.white.opacity(0.78))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }

    private func eventIconColor(_ event: SessionEvent) -> Color {
        switch event.kind {
        case .user:          return .white.opacity(0.8)
        case .assistantText: return accent
        case .toolUse:       return accent
        case .thinking:      return .white.opacity(0.5)
        case .toolResult:    return event.isError
            ? Color(red: 0.94, green: 0.45, blue: 0.45)
            : .white.opacity(0.6)
        }
    }

    private func eventIconBackground(_ event: SessionEvent) -> Color {
        switch event.kind {
        case .user:          return Color.white.opacity(0.1)
        case .assistantText: return accentDim
        case .toolUse:       return accentDim
        case .thinking:      return Color.white.opacity(0.06)
        case .toolResult:    return event.isError
            ? Color.red.opacity(0.14)
            : Color.white.opacity(0.06)
        }
    }

    private func eventLabelColor(_ event: SessionEvent) -> Color {
        switch event.kind {
        case .user:          return .white
        case .assistantText: return accent
        case .toolUse:       return accent
        case .thinking:      return .white.opacity(0.6)
        case .toolResult:    return event.isError
            ? Color(red: 0.94, green: 0.55, blue: 0.55)
            : .white.opacity(0.75)
        }
    }

    private var appearancePickerHeader: some View {
        HStack {
            Text("Appearance")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            Button { showingAppearancePicker = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))

            TextField("Filter sessions…", text: $filterQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(.white)

            if !filterQuery.isEmpty {
                Button { filterQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    // MARK: - Sessions section

    private var filteredSessions: [ClaudeSession] {
        let q = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return monitor.sessions }
        return monitor.sessions.filter { session in
            session.projectName.lowercased().contains(q)
            || session.cwd.lowercased().contains(q)
            || session.shortStatus.lowercased().contains(q)
            || session.model.lowercased().contains(q)
        }
    }

    @ViewBuilder
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Sessions", count: filteredSessions.count)

            if monitor.sessions.isEmpty {
                sessionsEmptyState
            } else if filteredSessions.isEmpty {
                Text("No matches for \"\(filterQuery)\"")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 5) {
                    ForEach(filteredSessions.prefix(8)) { session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    private var sessionsEmptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.3))
            Text("No active Claude sessions")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
            Spacer()
        }
        .padding(.vertical, 10)
    }

    private func sectionLabel(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
                .tracking(0.6)
            if let count = count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    // MARK: - Heatmap section

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionLabel(heatmapDayLabel, count: nil)

                // Prev-day button — always enabled
                Button {
                    heatmap.advanceDay(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Previous day")

                // Next-day button — disabled (dimmed) when already
                // viewing today, since we don't scan future days.
                Button {
                    heatmap.advanceDay(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(heatmap.isViewingToday
                            ? .white.opacity(0.2)
                            : .white.opacity(0.6))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(heatmap.isViewingToday)
                .help("Next day")

                Spacer()

                // Header text doubles as a heatmap tooltip — when no
                // cell is hovered it shows the day's total; when one
                // is hovered it shows that hour's count.
                Text(heatmapHeaderText)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(
                        hoveredHeatmapHour != nil ? accent : .white.opacity(0.4)
                    )
                    .monospacedDigit()
                    .animation(.easeOut(duration: 0.12), value: hoveredHeatmapHour)
            }

            heatmapStrip

            // Hour legend (every 6 hours)
            HStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Group {
                        if hour % 6 == 0 {
                            Text("\(hour)")
                                .font(.system(size: 8, design: .rounded))
                                .foregroundColor(.white.opacity(0.35))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // Per-hour project breakdown — fixed-height row so the
            // section doesn't reflow when you hover. Empty when no
            // cell is hovered, populated with the projects that had
            // events in that hour.
            heatmapProjectRow
                .frame(height: 14)
        }
    }

    @ViewBuilder
    private var heatmapProjectRow: some View {
        if let hour = hoveredHeatmapHour {
            let projects = heatmap.projects(forHour: hour)
            if projects.isEmpty {
                Text("no projects")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(projects, id: \.name) { entry in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(accent)
                                    .frame(width: 5, height: 5)
                                Text(entry.name)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.85))
                                Text("·")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundColor(.white.opacity(0.3))
                                Text("\(entry.count)")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.6))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Color.clear
        }
    }

    private var heatmapStrip: some View {
        let maxCount = max(heatmap.maxCount, 1)
        // Only show the "now" indicator when looking at today's
        // heatmap. For past days, there's no "now" to point at.
        let currentHour = heatmap.isViewingToday
            ? Calendar.current.component(.hour, from: Date())
            : -1

        return HStack(spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                let count = heatmap.hourlyCounts[hour]
                let intensity = Double(count) / Double(maxCount)
                let isHovered = hoveredHeatmapHour == hour
                let isCurrentHour = hour == currentHour
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        cellColor(intensity: intensity, isCurrent: isCurrentHour)
                    )
                    .frame(height: 22)
                    .overlay(
                        // Outline: hovered cell gets a bright border;
                        // current hour gets a subtle accent border.
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                isHovered
                                    ? Color.white.opacity(0.85)
                                    : (isCurrentHour ? accent : .clear),
                                lineWidth: isHovered ? 1.2 : 1
                            )
                    )
                    .scaleEffect(isHovered ? 1.08 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: isHovered)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            hoveredHeatmapHour = hour
                        } else if hoveredHeatmapHour == hour {
                            hoveredHeatmapHour = nil
                        }
                    }
            }
        }
    }

    /// Inline header text for the heatmap section. Day total when idle,
    /// per-hour summary when hovering a cell.
    private var heatmapHeaderText: String {
        if let hour = hoveredHeatmapHour {
            let count = heatmap.hourlyCounts[hour]
            return hourTooltip(hour: hour, count: count)
        }
        return "\(heatmap.totalToday) events"
    }

    /// Label for the heatmap section header — "Today", "Yesterday",
    /// or a short date like "Mon Apr 13" for older days.
    private var heatmapDayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(heatmap.viewingDate) { return "Today" }
        if cal.isDateInYesterday(heatmap.viewingDate) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f.string(from: heatmap.viewingDate)
    }

    private func cellColor(intensity: Double, isCurrent: Bool) -> Color {
        if intensity <= 0 {
            return Color.white.opacity(0.04)
        }
        // Ramp from dim orange → full Claude orange based on activity.
        let minOpacity = 0.18
        let maxOpacity = 0.95
        let op = minOpacity + intensity * (maxOpacity - minOpacity)
        return accent.opacity(op)
    }

    private func hourTooltip(hour: Int, count: Int) -> String {
        let suffix = count == 1 ? "event" : "events"
        let h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        let ampm = hour < 12 ? "AM" : "PM"
        return "\(h12) \(ampm) — \(count) \(suffix)"
    }

    // MARK: - Always-allowed section

    private var alwaysAllowedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Always Allowed", count: hookBridge.alwaysAllowedTools.count)

            if hookBridge.alwaysAllowedTools.isEmpty {
                Text("Click \"Always\" on a permission request to pin a tool here.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(hookBridge.alwaysAllowedTools).sorted(), id: \.self) { tool in
                            allowedChip(tool)
                        }
                    }
                }
            }
        }
    }

    private func allowedChip(_ tool: String) -> some View {
        HStack(spacing: 5) {
            Text(tool)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(accent)
            Button { hookBridge.removeFromAlwaysAllow(tool) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(accent.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(accentDim)
                .overlay(Capsule().strokeBorder(accentBorder, lineWidth: 0.5))
        )
    }

    // MARK: - Permission panel

    @ViewBuilder
    private func standardPermissionBody(_ permission: PendingPermission) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tool header: icon + name + short verb
            HStack(spacing: 9) {
                Image(systemName: toolIconName(for: permission.toolName))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent)
                    .frame(width: 20, alignment: .center)
                Text(permission.toolName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                if let verb = toolVerb(for: permission.toolName) {
                    Text(verb)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer(minLength: 0)
            }

            // Smart summary — renders commands, paths, URLs etc. with
            // structure rather than as one flat monospace blob.
            summaryContent(for: permission)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )

        Spacer(minLength: 0)

        // Action row — Deny (ghost) + Allow (solid accent, primary).
        // "Always allow" lives below as a subtle tertiary action so
        // the primary choice is visually uncluttered.
        HStack(spacing: 8) {
            PermissionButton(
                label: "Deny",
                style: .ghost,
                accent: accent,
                action: { hookBridge.deny(permission) }
            )
            .keyboardShortcut(.cancelAction)

            PermissionButton(
                label: "Allow",
                style: .primary,
                accent: accent,
                action: { hookBridge.allow(permission) }
            )
            .keyboardShortcut(.defaultAction)
        }

        Button { hookBridge.allowAlways(permission) } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 10, weight: .semibold))
                Text("Always allow ") + Text(permission.toolName).fontWeight(.semibold)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Permission helpers

    /// SF Symbol name mapped from Claude Code tool name.
    private func toolIconName(for tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "bashoutput", "killshell":
            return "terminal"
        case "read", "notebookread":
            return "doc.text"
        case "write":
            return "doc.badge.plus"
        case "edit", "multiedit", "notebookedit":
            return "pencil.and.outline"
        case "grep":
            return "magnifyingglass"
        case "glob":
            return "rectangle.stack.badge.play"
        case "ls":
            return "folder"
        case "webfetch":
            return "arrow.down.circle"
        case "websearch":
            return "globe"
        case "task":
            return "square.stack.3d.up"
        case "todowrite":
            return "checklist"
        case "askuserquestion":
            return "questionmark.bubble"
        case "slashcommand":
            return "command"
        default:
            return "wrench.and.screwdriver"
        }
    }

    /// Short verb describing what the tool wants to do. Nil when the
    /// tool name alone is self-explanatory.
    private func toolVerb(for tool: String) -> String? {
        switch tool.lowercased() {
        case "bash":         return "wants to run a shell command"
        case "bashoutput":   return "wants to read shell output"
        case "killshell":    return "wants to stop a shell"
        case "read":         return "wants to read a file"
        case "write":        return "wants to create a file"
        case "edit":         return "wants to edit a file"
        case "multiedit":    return "wants to edit a file"
        case "notebookedit": return "wants to edit a notebook"
        case "notebookread": return "wants to read a notebook"
        case "grep":         return "wants to search"
        case "glob":         return "wants to list files"
        case "ls":           return "wants to list files"
        case "webfetch":     return "wants to fetch a URL"
        case "websearch":    return "wants to search the web"
        case "task":         return "wants to spawn a subagent"
        case "todowrite":    return "wants to update todos"
        default:             return nil
        }
    }

    /// Smart summary for the permission body. Picks the structure based
    /// on which field of `toolInput` is populated — commands get code-
    /// block styling, file paths get directory/basename hierarchy, URLs
    /// get host/path split, Edit/Write show the actual diff/content.
    @ViewBuilder
    private func summaryContent(for permission: PendingPermission) -> some View {
        let input = permission.toolInput
        let tool = permission.toolName.lowercased()

        if let cmd = input["command"] as? String, !cmd.isEmpty {
            commandBlock(cmd)
        } else if tool == "edit", let path = input["file_path"] as? String {
            editBlock(
                path: path,
                oldString: input["old_string"] as? String ?? "",
                newString: input["new_string"] as? String ?? ""
            )
        } else if tool == "multiedit", let path = input["file_path"] as? String {
            multiEditBlock(path: path, edits: input["edits"] as? [[String: Any]] ?? [])
        } else if tool == "write", let path = input["file_path"] as? String {
            writeBlock(path: path, content: input["content"] as? String ?? "")
        } else if let path = input["file_path"] as? String, !path.isEmpty {
            filePathBlock(path)
        } else if let url = input["url"] as? String, !url.isEmpty {
            urlBlock(url)
        } else if let pattern = input["pattern"] as? String, !pattern.isEmpty {
            labeledMono(label: "matching", value: pattern)
        } else if let query = input["query"] as? String, !query.isEmpty {
            labeledMono(label: "query", value: query)
        } else if !permission.summaryText.isEmpty {
            ScrollView {
                Text(permission.summaryText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 160)
        }
    }

    /// Edit tool: file header + red/green diff of old_string → new_string.
    private func editBlock(path: String, oldString: String, newString: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            filePathBlock(path)
            ScrollView {
                diffBlock(oldString: oldString, newString: newString)
            }
            .frame(maxHeight: 220)
        }
    }

    /// MultiEdit: file header + "N edits" label + a scroll of each diff.
    private func multiEditBlock(path: String, edits: [[String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            filePathBlock(path)
            HStack(spacing: 6) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                Text("\(edits.count) edit\(edits.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<edits.count, id: \.self) { idx in
                        let edit = edits[idx]
                        diffBlock(
                            oldString: edit["old_string"] as? String ?? "",
                            newString: edit["new_string"] as? String ?? "",
                            indexLabel: "edit \(idx + 1)"
                        )
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    /// Write tool: file header + preview of the content being written.
    private func writeBlock(path: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            filePathBlock(path)
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(accent.opacity(0.7))
                Text("\(content.split(whereSeparator: \.isNewline).count) lines · \(content.count) chars")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
            }
            ScrollView {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(11)
            }
            .frame(maxHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            )
        }
    }

    /// Renders a red/green unified diff of the before/after strings. If
    /// both are multi-line we show them in stacked minus/plus blocks with
    /// line-level prefix markers.
    private func diffBlock(
        oldString: String,
        newString: String,
        indexLabel: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label = indexLabel {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 11)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(oldString.split(separator: "\n", omittingEmptySubsequences: false).indices, id: \.self) { i in
                    let line = oldString.split(separator: "\n", omittingEmptySubsequences: false)[i]
                    diffLine(sign: "-", text: String(line), color: Color(red: 0.92, green: 0.35, blue: 0.35))
                }
                ForEach(newString.split(separator: "\n", omittingEmptySubsequences: false).indices, id: \.self) { i in
                    let line = newString.split(separator: "\n", omittingEmptySubsequences: false)[i]
                    diffLine(sign: "+", text: String(line), color: Color(red: 0.44, green: 0.83, blue: 0.52))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
    }

    /// One row of a diff — a colored `+`/`-` sigil followed by monospace
    /// text. The sigil background has a faint tint matching its color.
    private func diffLine(sign: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(sign)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 10, alignment: .center)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }

    /// Shell command block — monospace, dark background, `$` prompt.
    private func commandBlock(_ cmd: String) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: 8) {
                Text("$")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(accent.opacity(0.7))
                Text(cmd)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 160)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
    }

    /// File path split into parent dir (dim) + basename (bright) so you
    /// can read the filename at a glance even on long absolute paths.
    private func filePathBlock(_ path: String) -> some View {
        let ns = path as NSString
        let basename = ns.lastPathComponent
        let parent = ns.deletingLastPathComponent
        let abbreviatedParent = parent
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")

        return HStack(spacing: 0) {
            Image(systemName: "doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
                .padding(.trailing, 7)

            VStack(alignment: .leading, spacing: 1) {
                if !abbreviatedParent.isEmpty && abbreviatedParent != "/" {
                    Text(abbreviatedParent + "/")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(basename)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
    }

    /// URL with host highlighted and path dimmed.
    private func urlBlock(_ raw: String) -> some View {
        let url = URL(string: raw)
        let host = url?.host ?? raw
        let tail: String = {
            guard let url else { return "" }
            var t = url.path
            if let q = url.query { t += "?\(q)" }
            return t
        }()

        return HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))

            Group {
                Text(host)
                    .foregroundColor(.white.opacity(0.95))
                    .fontWeight(.semibold)
                + Text(tail)
                    .foregroundColor(.white.opacity(0.5))
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(2)
            .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
    }

    /// Tiny label + monospace value row for patterns, queries, etc.
    private func labeledMono(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.22))
        )
    }

    @ViewBuilder
    private func questionBody(_ permission: PendingPermission) -> some View {
        let q = permission.question

        VStack(alignment: .leading, spacing: 10) {
            if !q.isEmpty {
                Text(q)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(permission.askOptions) { option in
                        Button {
                            hookBridge.selectQuestionOption(permission, option: option)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let desc = option.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 10, design: .rounded))
                                        .foregroundColor(.white.opacity(0.6))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(accent.opacity(0.18))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9)
                                            .strokeBorder(accentBorder, lineWidth: 0.5)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )

        Spacer(minLength: 0)

        Button { hookBridge.deny(permission) } label: {
            Text("Cancel")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    private func permissionPanel(_ permission: PendingPermission) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 28,
            bottomTrailingRadius: 28,
            topTrailingRadius: 0,
            style: .continuous
        )

        let isQuestion = permission.isAskUserQuestion && !permission.askOptions.isEmpty

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                appearanceMenu {
                    BuddyFace(mode: .curious, size: 10)
                        .frame(width: 40, height: 22)
                }
                Text(isQuestion ? "Claude is asking" : "Permission Request")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                // "1 of N" pill when there are other requests queued
                // behind this one. Surfaces parallel tool bursts so the
                // user knows more are coming rather than thinking stuff
                // disappeared.
                if hookBridge.queuedBehindCurrent > 0 {
                    Text("1 of \(hookBridge.pendingPermissions.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(accentDim)
                                .overlay(Capsule().strokeBorder(accentBorder, lineWidth: 0.5))
                        )
                }

                Spacer()
                Text(permission.projectName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            }

            if isQuestion {
                questionBody(permission)
            } else {
                standardPermissionBody(permission)
            }
        }
        .padding(.top, max(notchHeight, 14) + 14)
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .frame(width: expandedWidth, height: expandedHeight, alignment: .top)
        .background(shape.fill(Color.black))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
        .contentShape(shape)
        .contextMenu {
            Button("Quit Notch Pilot") { NSApp.terminate(nil) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            appearanceMenu {
                BuddyFace(mode: mode, size: 11)
                    .frame(width: 44, height: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Notch Pilot")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer(minLength: 4)

            // Center: usage pill — summary of claude usage in the
            // rolling 5-hour window. Hover shows a detail popover
            // below with the full breakdown.
            usagePill

            Spacer(minLength: 4)

            statBadge
            customizeButton
            if updateChecker.updateAvailable {
                updateButton
            }
            quitButton
        }
    }

    // MARK: - Usage pill (center of header)

    @State private var usageDetailShown = false

    /// Click-to-toggle the usage card. When live API data is
    /// available we show the exact 5h utilization % (same number
    /// Claude's account page shows). Falls back to a jsonl-derived
    /// raw message count if the user isn't signed in or the fetch
    /// failed.
    private var usagePill: some View {
        return Button {
            usageDetailShown.toggle()
            if usageDetailShown { usage.refreshIfNeeded() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(usageTint(percent: usage.live?.fiveHour?.utilization ?? 0))
                usagePillContent
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    // Progress fill — clip a rectangle to the capsule
                    // shape so the left edge stays flush at low %.
                    if let util = usage.live?.fiveHour?.utilization {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(usageTint(percent: util).opacity(0.28))
                                .frame(width: geo.size.width * min(util / 100, 1.0))
                        }
                        .clipShape(Capsule(style: .continuous))
                    }
                }
                .overlay(
                    Capsule()
                        .strokeBorder(
                            usageDetailShown
                                ? accentBorder.opacity(0.6)
                                : Color.white.opacity(0.08),
                            lineWidth: 0.5
                        )
                )
            )
        }
        .buttonStyle(.plain)
        .help("Click for usage details")
        .onAppear { usage.refreshIfNeeded() }
    }

    @ViewBuilder
    private var usagePillContent: some View {
        if let live5h = usage.live?.fiveHour {
            let pct = Int(live5h.utilization.rounded())
            Text(verbatim: "\(pct)%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(verbatim: "· 5h")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
        } else {
            // Fallback: raw message count from jsonls when we can't
            // reach the API (offline, not signed in, etc.).
            Text(verbatim: "\(usage.last5h.messageCount)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(verbatim: "· 5h")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    /// Tint based on a 0-100 utilization percent. Accent under 70%,
    /// amber 70-94, red 95+.
    private func usageTint(percent: Double) -> Color {
        if percent >= 95 { return Color(red: 0.97, green: 0.45, blue: 0.45) }
        if percent >= 70 { return Color(red: 0.97, green: 0.78, blue: 0.40) }
        return accent
    }

    /// Detail card — drops below the usage pill when clicked.
    /// Shows the live utilization percentages pulled from Anthropic's
    /// oauth/usage endpoint (same data as claude.ai/settings), with
    /// jsonl-derived token breakdown as bonus context.
    ///
    /// Card has a fixed outer size; the scrollable body makes sure
    /// long content (several weekly limit rows + token breakdown +
    /// extra credits) never overflows the panel.
    private var usageDetailPopover: some View {
        VStack(spacing: 0) {
            // Header with explicit close button — sticky above the
            // scroll content so it's always reachable.
            HStack {
                Text("USAGE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Button { usageDetailShown = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let live = usage.live {
                        liveUsageSection(live)
                    } else {
                        noLiveDataSection
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)

                    // Token breakdown for today (from local jsonls,
                    // always available regardless of API state).
                    VStack(alignment: .leading, spacing: 5) {
                        Text("TODAY · TOKEN BREAKDOWN")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.6)
                            .foregroundColor(.white.opacity(0.4))
                        tokenRow(label: "Input", value: usage.today.inputTokens)
                        tokenRow(label: "Output", value: usage.today.outputTokens)
                        tokenRow(label: "Cache read", value: usage.today.cacheReadTokens, dim: true)
                        tokenRow(label: "Cache write", value: usage.today.cacheCreationTokens, dim: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: expandedHeight - 140)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { /* swallow */ }
    }

    @ViewBuilder
    private func liveUsageSection(_ live: ClaudeUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let w = live.fiveHour {
                liveUsageRow(label: "Current session", window: w)
            }
            if live.sevenDay != nil || live.sevenDaySonnet != nil || live.sevenDayOpus != nil {
                Text("WEEKLY LIMITS")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 2)
                if let w = live.sevenDay {
                    liveUsageRow(label: "All models", window: w)
                }
                if let w = live.sevenDaySonnet {
                    liveUsageRow(label: "Sonnet only", window: w)
                }
                if let w = live.sevenDayOpus {
                    liveUsageRow(label: "Opus only", window: w)
                }
            }
            if let extra = live.extraUsage, extra.isEnabled {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.vertical, 2)
                extraCreditRow(extra)
            }
        }
    }

    private func liveUsageRow(label: String, window: ClaudeUsage.Window) -> some View {
        let pct = window.utilization
        let ratio = min(pct / 100, 1.0)
        let tint = usageTint(percent: pct)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Text(verbatim: "\(Int(pct.rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tint)
                        .frame(width: max(4, geo.size.width * ratio))
                }
            }
            .frame(height: 5)
            if let reset = window.resetsAt, reset > Date() {
                Text(verbatim: "resets in \(relativeDurationLabel(reset))")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .monospacedDigit()
            }
        }
    }

    private func extraCreditRow(_ extra: ClaudeUsage.ExtraUsage) -> some View {
        let pct = extra.utilization
        let ratio = min(pct / 100, 1.0)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Extra credits")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Text(verbatim: "\(Int(pct.rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(accent)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(accent)
                        .frame(width: max(4, geo.size.width * ratio))
                }
            }
            .frame(height: 5)
            Text(verbatim: "\(Int(extra.usedCredits.rounded())) / \(extra.monthlyLimit) credits")
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .monospacedDigit()
        }
    }

    /// Shown when we can't pull live usage data (user isn't signed
    /// into Claude Code, the token is expired, etc.). Falls back to
    /// the jsonl-derived 5h message count and a link to claude.ai.
    private var noLiveDataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                Text("Couldn't fetch live usage")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))
            }
            Text("Sign in to Claude Code, or check your connection. Showing local activity below.")
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(usage.last5h.messageCount)")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Text("messages · 5h")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
            }
            Button {
                if let url = URL(string: "https://claude.ai/settings/billing") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Open claude.ai usage")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accentDim)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(accentBorder, lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// "4h 28m", "2d 3h", etc. — compact duration between now and a
    /// future date, used for the window reset countdown.
    private func relativeDurationLabel(_ future: Date) -> String {
        let seconds = Int(future.timeIntervalSince(Date()))
        if seconds <= 0 { return "now" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let d = h / 24
        if d > 0 {
            let rh = h % 24
            return "\(d)d \(rh)h"
        }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func tokenRow(label: String, value: Int, dim: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(dim ? .white.opacity(0.35) : .white.opacity(0.7))
            Spacer()
            Text(verbatim: formatTokens(value))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(dim ? .white.opacity(0.45) : .white.opacity(0.9))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Compact token count: 1234 → "1.2k", 12345 → "12k",
    /// 1234567 → "1.2M". Keeps header values readable.
    private func formatTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 {
            let v = Double(n) / 1000
            return String(format: n < 10_000 ? "%.1fk" : "%.0fk", v)
        }
        let v = Double(n) / 1_000_000
        return String(format: "%.1fM", v)
    }

    /// Tiny sliders icon that opens the appearance picker. Separate from
    /// the buddy-click affordance so the entry point is discoverable
    /// without adding visual noise — dim by default, brightens on hover.
    @State private var customizeHovered = false
    private var customizeButton: some View {
        Button {
            showingAppearancePicker.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(
                    showingAppearancePicker || customizeHovered
                        ? .white.opacity(0.9)
                        : .white.opacity(0.35)
                )
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(
                        customizeHovered || showingAppearancePicker
                            ? Color.white.opacity(0.08)
                            : Color.clear
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { customizeHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: customizeHovered)
        .animation(.easeOut(duration: 0.15), value: showingAppearancePicker)
        .help("Customize buddy style, color, and sounds")
    }

    // MARK: - Update badge

    @State private var updateHovered = false
    private var updateButton: some View {
        Button {
            updateChecker.performUpdate()
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if updateChecker.state == .updating {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundColor(
                    updateHovered ? .white.opacity(0.9) : .white.opacity(0.35)
                )
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(
                        updateHovered
                            ? Color.white.opacity(0.08)
                            : Color.clear
                    )
                )
                .contentShape(Circle())

                // Green dot
                if updateChecker.state != .updating {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .offset(x: 1, y: -1)
                }
            }
            .overlay(alignment: .bottom) {
                if updateHovered {
                    Text(updateChecker.latestVersion.map { "v\($0) available" }
                         ?? "Update available")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.85))
                        )
                        .fixedSize()
                        .offset(y: 28)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(updateChecker.state == .updating)
        .onHover { updateHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: updateHovered)
    }

    // MARK: - Node.js missing banner

    private var nodeMissingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Node.js not found")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text("Permission prompts won't appear. Run: brew install node")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer(minLength: 4)

            Button {
                updateChecker.nodeBannerDismissed = true
                UserDefaults.standard.set(true, forKey: "notchpilot.nodeMissingDismissed")
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 0.5)
                )
        )
    }

    /// Power icon that quits the app. The menu bar icon was removed to
    /// keep Notch Pilot's surface area limited to the notch itself, so
    /// this is now the only discoverable quit path (besides right-click
    /// context menus). Dim until hovered, then reddish.
    @State private var quitHovered = false
    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Image(systemName: "power")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(
                    quitHovered
                        ? Color(red: 0.96, green: 0.45, blue: 0.45)
                        : .white.opacity(0.35)
                )
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(
                        quitHovered
                            ? Color(red: 0.96, green: 0.35, blue: 0.35).opacity(0.12)
                            : Color.clear
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { quitHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: quitHovered)
        .help("Quit Notch Pilot")
    }

    // MARK: - Appearance (style + color) picker

    /// Wraps any buddy face view in a clickable button that toggles the
    /// inline appearance picker overlay on the expanded panel. We avoid
    /// `.popover` because macOS popovers are separate windows — when the
    /// mouse enters them it exits the notch window's hover area and the
    /// panel collapses.
    private func appearanceMenu<Label: View>(
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            showingAppearancePicker.toggle()
        } label: {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to change buddy style and color")
    }

    private var appearancePickerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("STYLE")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundColor(.white.opacity(0.45))

            HStack(spacing: 10) {
                ForEach(BuddyStyle.allCases) { style in
                    stylePickerChip(style)
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            Text("COLOR")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundColor(.white.opacity(0.45))

            HStack(spacing: 12) {
                ForEach(BuddyColor.allCases) { color in
                    colorPickerChip(color)
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            behaviorSection

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            speechSection

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            soundSection
        }
    }

    private var speechSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(
                    systemName: prefs.speechEnabled
                        ? "bubble.left.fill"
                        : "bubble.left"
                )
                .font(.system(size: 12))
                .foregroundColor(prefs.speechEnabled ? accent : .white.opacity(0.4))

                Text("SPEECH")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundColor(.white.opacity(0.45))

                Spacer()

                Toggle("", isOn: $prefs.speechEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(accent)
                    .labelsHidden()
            }

            VStack(spacing: 6) {
                ForEach(SpeechEvent.allCases) { event in
                    speechEventRow(event)
                }
            }
            .opacity(prefs.speechEnabled ? 1 : 0.35)
            .allowsHitTesting(prefs.speechEnabled)
        }
    }

    private func speechEventRow(_ event: SpeechEvent) -> some View {
        let enabled = prefs.speechEvents[event] ?? true
        return HStack(spacing: 8) {
            Image(systemName: event.icon)
                .font(.system(size: 10))
                .foregroundColor(
                    enabled && prefs.speechEnabled
                        ? accent
                        : .white.opacity(0.35)
                )
                .frame(width: 14)

            Text(event.label)
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.85))

            Spacer()

            // Preview button — fires a sample speech for this event
            // so the user can see what it looks like without waiting
            // for the real trigger.
            Button {
                previewSpeech(for: event)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Preview \(event.label)")

            Toggle(
                "",
                isOn: Binding(
                    get: { prefs.speechEvents[event] ?? true },
                    set: { prefs.setSpeechEvent(event, $0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(accent)
            .labelsHidden()
        }
    }

    /// Fire a sample speech pop-out for the given event so the user
    /// can see what it'll look like when the real thing triggers.
    /// Bypasses the rate limiter + dedup.
    private func previewSpeech(for event: SpeechEvent) {
        switch event {
        case .sessionFinished:
            speechController.preview(
                kind: .sessionFinished,
                title: monitor.sessions.first?.projectName ?? "notch-pilot",
                subtitle: "done",
                icon: "checkmark.circle.fill",
                tint: .accent
            )
        }
    }

    /// Behaviour toggles — things that change how the panel behaves,
    /// separate from appearance or sound.
    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BEHAVIOR")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundColor(.white.opacity(0.45))

            behaviorRow(
                iconOn: "pin.fill",
                iconOff: "pin.slash",
                title: "Always visible",
                subtitle: "Keep the buddy pinned even when Claude is idle",
                isOn: $prefs.alwaysVisible
            )

            behaviorRow(
                iconOn: "power",
                iconOff: "power",
                title: "Start at login",
                subtitle: "Auto-launch Notch Pilot when you log in",
                isOn: $prefs.startAtLogin
            )

            behaviorRow(
                iconOn: "hand.tap.fill",
                iconOff: "hand.tap",
                title: "Haptic feedback",
                subtitle: "A subtle trackpad tick when the panel opens or closes",
                isOn: $prefs.hapticsEnabled
            )
        }
    }

    @ViewBuilder
    private func behaviorRow(
        iconOn: String,
        iconOff: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isOn.wrappedValue ? iconOn : iconOff)
                .font(.system(size: 12))
                .foregroundColor(isOn.wrappedValue ? accent : .white.opacity(0.4))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                Text(subtitle)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(accent)
                .labelsHidden()
        }
    }

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(
                    systemName: prefs.voiceEnabled
                        ? "speaker.wave.2.fill"
                        : "speaker.slash.fill"
                )
                .font(.system(size: 12))
                .foregroundColor(prefs.voiceEnabled ? accent : .white.opacity(0.4))

                Text("SOUND")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundColor(.white.opacity(0.45))

                Spacer()

                Toggle("", isOn: $prefs.voiceEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(accent)
                    .labelsHidden()
            }

            VStack(spacing: 6) {
                ForEach(VoiceEvent.allCases) { event in
                    voiceEventRow(event)
                }
            }
            .opacity(prefs.voiceEnabled ? 1 : 0.35)
            .allowsHitTesting(prefs.voiceEnabled)
        }
    }

    private func voiceEventRow(_ event: VoiceEvent) -> some View {
        let enabled = prefs.voiceEvents[event] ?? true
        return HStack(spacing: 8) {
            Image(systemName: event.icon)
                .font(.system(size: 10))
                .foregroundColor(
                    enabled && prefs.voiceEnabled
                        ? accent
                        : .white.opacity(0.35)
                )
                .frame(width: 14)

            Text(event.label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.85))

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { prefs.voiceEvents[event] ?? true },
                    set: { prefs.setVoiceEvent(event, $0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(accent)
            .labelsHidden()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private func stylePickerChip(_ style: BuddyStyle) -> some View {
        let selected = prefs.style == style
        return Button {
            prefs.style = style
        } label: {
            VStack(spacing: 7) {
                stylePreview(style)
                    .frame(width: 44, height: 26)
                Text(style.label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(selected ? .white : .white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.1 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        selected ? prefs.color.base : Color.white.opacity(0.08),
                        lineWidth: selected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func stylePreview(_ style: BuddyStyle) -> some View {
        // A one-off renderer showing each buddy style in the user's color
        // so the picker chips can display live mini-previews.
        let c = prefs.color.base
        switch style {
        case .eyes:
            HStack(spacing: 4) {
                Circle().fill(c).frame(width: 7, height: 7)
                Circle().fill(c).frame(width: 7, height: 7)
            }
        case .orb:
            Circle()
                .fill(c)
                .frame(width: 17, height: 17)
                .overlay(
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.4), .clear],
                                center: UnitPoint(x: 0.3, y: 0.28),
                                startRadius: 0,
                                endRadius: 9
                            )
                        )
                )
        case .bars:
            HStack(spacing: 2) {
                ForEach([10, 14, 8, 12], id: \.self) { h in
                    Capsule().fill(c).frame(width: 3, height: CGFloat(h))
                }
            }
        case .ghost:
            ZStack {
                GhostShape()
                    .fill(c)
                    .frame(width: 18, height: 22)
                HStack(spacing: 4) {
                    Circle().fill(.white).frame(width: 3.5, height: 3.5)
                    Circle().fill(.white).frame(width: 3.5, height: 3.5)
                }
                .offset(y: -2)
            }
        case .cat:
            ZStack {
                Circle().fill(c).frame(width: 18, height: 18)
                TriangleShape()
                    .fill(c)
                    .frame(width: 6, height: 7)
                    .offset(x: -6, y: -10)
                TriangleShape()
                    .fill(c)
                    .frame(width: 6, height: 7)
                    .offset(x: 6, y: -10)
                HStack(spacing: 5) {
                    Circle().fill(.white).frame(width: 3.5, height: 3.5)
                    Circle().fill(.white).frame(width: 3.5, height: 3.5)
                }
            }
            .frame(width: 22, height: 22)
        case .bunny:
            ZStack {
                HStack(spacing: 2) {
                    Capsule().fill(c).frame(width: 3, height: 9)
                    Capsule().fill(c).frame(width: 3, height: 9)
                }
                .offset(y: -9)
                Ellipse().fill(c).frame(width: 16, height: 14)
                HStack(spacing: 5) {
                    Circle().fill(.white).frame(width: 3, height: 3)
                    Circle().fill(.white).frame(width: 3, height: 3)
                }
            }
            .frame(width: 18, height: 26)
        }
    }

    private func colorPickerChip(_ color: BuddyColor) -> some View {
        let selected = prefs.color == color
        return Button {
            prefs.color = color
        } label: {
            Circle()
                .fill(color.base)
                .frame(width: 26, height: 26)
                .overlay(
                    Circle()
                        .strokeBorder(
                            selected ? Color.white : Color.white.opacity(0.0),
                            lineWidth: 2.5
                        )
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            selected ? color.base : Color.white.opacity(0.15),
                            lineWidth: 1
                        )
                        .padding(selected ? -3 : 0)
                )
                .help(color.label)
        }
        .buttonStyle(.plain)
    }

    private var statBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(activeCount > 0 ? accent : Color.white.opacity(0.3))
                .frame(width: 6, height: 6)
            Text("\(activeCount) / \(monitor.sessions.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.75))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private var headerSubtitle: String {
        if activeCount > 0 {
            return "\(activeCount) session\(activeCount == 1 ? "" : "s") working"
        }
        if monitor.processCount > 0 {
            return "claude running, waiting"
        }
        return ""
    }

    private var divider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.0), .white.opacity(0.12), .white.opacity(0.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }

    // MARK: - Session row

    private func sessionRow(_ s: ClaudeSession) -> some View {
        Button {
            inspectedSession = s
        } label: {
            sessionRowContent(s)
        }
        .buttonStyle(.plain)
        .help("Click to see what this session is up to")
    }

    private func sessionRowContent(_ s: ClaudeSession) -> some View {
        let isActive = !s.shortStatus.isEmpty

        return HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(isActive ? accent : Color.white.opacity(0.25))
                .frame(width: 7, height: 7)
                .shadow(
                    color: isActive ? accent.opacity(0.55) : .clear,
                    radius: 3
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if isActive {
                        Text(s.shortStatus)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(accentDim))
                    }
                    Spacer(minLength: 4)
                }

                HStack(spacing: 6) {
                    if !s.model.isEmpty {
                        Text(compactModelName(s.model))
                            .font(.system(size: 9, design: .rounded))
                            .foregroundColor(.white.opacity(0.45))
                        Circle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 2, height: 2)
                    }
                    Text("up \(durationLabel(s.startTime))")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                    Spacer(minLength: 4)
                    Text(relativeTime(s.lastActivity))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            modeBadge(hookBridge.liveModes[s.cwd] ?? s.nativeMode)

            Button {
                if !s.cwd.isEmpty {
                    TerminalJumper.jump(toCwd: s.cwd)
                }
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Jump to terminal for \(s.projectName)")
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(isActive ? 0.08 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isActive ? accentBorder.opacity(0.45) : Color.clear,
                    lineWidth: 0.5
                )
        )
    }

    /// Read-only badge showing Claude's current native permission mode for
    /// the session, parsed from the jsonl. We intentionally don't let the
    /// user edit it from the notch — the source of truth is Claude itself
    /// (changed via Shift+Tab in the TUI or the --permission-mode flag).
    private func modeBadge(_ nativeMode: String) -> some View {
        let (label, tint) = modeDisplay(nativeMode)
        return HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.16))
                .overlay(
                    Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 0.5)
                )
        )
        .help("Claude's permission mode. Change it in the terminal with ⇧⇥.")
    }

    private func modeDisplay(_ raw: String) -> (label: String, tint: Color) {
        switch raw {
        case "acceptEdits":
            return ("Accept", accent)
        case "plan":
            return ("Plan", Color(red: 0.46, green: 0.72, blue: 1.0))
        case "bypassPermissions", "bypass":
            return ("Bypass", Color(red: 0.96, green: 0.40, blue: 0.32))
        case "default", "":
            return ("Default", .white.opacity(0.6))
        default:
            return (raw, .white.opacity(0.6))
        }
    }

    /// Shortens model strings like "claude-opus-4-6" → "opus 4.6".
    private func compactModelName(_ raw: String) -> String {
        let lower = raw.lowercased()
        let family: String = {
            if lower.contains("opus") { return "opus" }
            if lower.contains("sonnet") { return "sonnet" }
            if lower.contains("haiku") { return "haiku" }
            return raw
        }()
        // Extract a trailing version like "4-6" or "4.5" → "4.6" / "4.5"
        let pattern = #"(\d+)[-.](\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(
            in: raw,
            range: NSRange(raw.startIndex..., in: raw)
           ),
           let maj = Range(match.range(at: 1), in: raw),
           let min = Range(match.range(at: 2), in: raw) {
            return "\(family) \(raw[maj]).\(raw[min])"
        }
        return family
    }

    private func durationLabel(_ start: Date) -> String {
        let s = Int(Date().timeIntervalSince(start))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 {
            let h = s / 3600
            let m = (s % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(s / 86400)d"
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// Polished allow/deny button. Primary style is a solid accent fill for
/// the affirmative action; ghost style is a subtle transparent button
/// used for Deny / Cancel. Both lift slightly on hover and press.
private struct PermissionButton: View {
    enum Style { case primary, ghost }

    let label: String
    let style: Style
    let accent: Color
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(foreground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                )
                .scaleEffect(hovered ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .ghost:   return .white.opacity(0.85)
        }
    }

    private var background: Color {
        switch style {
        case .primary:
            return hovered ? accent.opacity(0.85) : accent.opacity(0.7)
        case .ghost:
            return hovered ? Color.white.opacity(0.1) : Color.white.opacity(0.06)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary: return accent.opacity(0.6)
        case .ghost:   return Color.white.opacity(0.12)
        }
    }
}
