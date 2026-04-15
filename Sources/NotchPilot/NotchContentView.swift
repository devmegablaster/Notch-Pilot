import SwiftUI
import AppKit

struct NotchContentView: View {
    @ObservedObject var monitor: ClaudeMonitor
    @ObservedObject var hookBridge: HookBridge
    @ObservedObject var heatmap: HeatmapAggregator
    @ObservedObject var mouseMonitor: MouseMonitor
    @EnvironmentObject var prefs: BuddyPreferences
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    // Callbacks up to the owning NSPanel so it can resize/show in sync
    // with the view's logical state.
    var onVisibilityChange: (Bool) -> Void
    var onCollapsedSizeChange: (CGFloat) -> Void
    var onExpandedChange: (Bool) -> Void

    @State private var expanded = false
    // Synchronously-controlled visibility. Set to true the moment activity
    // appears; only set back to false after the fade-out delay elapses with
    // no fresh activity. Decoupled from `hasAnyActivity` so we don't race
    // against SwiftUI's body-then-onChange evaluation order.
    @State private var displayedVisible = false
    @State private var fadeOutToken = UUID()
    @State private var filterQuery: String = ""
    @State private var showingAppearancePicker = false
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
        displayedVisible
            || mouseMonitor.isHoveringNotch
            || expanded
            || showingAppearancePicker
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
        return ""
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

    // MARK: - Body

    var body: some View {
        Group {
            if shouldShow {
                if hasPendingPermission, let permission = hookBridge.pendingPermission {
                    permissionPanel(permission)
                        .transition(.opacity)
                } else if expanded {
                    expandedPanel
                        .transition(.opacity)
                } else {
                    collapsedPill
                        // Scale toward the center (where the notch lives) as
                        // we fade, so the left eye and right text appear to
                        // collapse INTO the notch on hide and grow OUT of
                        // the notch on show.
                        .transition(
                            .scale(scale: 0.05, anchor: .center)
                            .combined(with: .opacity)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: effectivelyExpanded)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: shouldShow)
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
                onCollapsedSizeChange(collapsedWidth)
            } else {
                expanded = false
            }
        }
        .onChange(of: effectivelyExpanded) { _, newValue in
            onExpandedChange(newValue)
        }
        .onChange(of: collapsedWidth) { _, newValue in
            onCollapsedSizeChange(newValue)
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
            onCollapsedSizeChange(collapsedWidth)
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

            // Right section: status text anchored to the left edge
            HStack(spacing: 0) {
                Text(currentStatus)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
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
            if hovering { expanded = true }
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
        .animation(.easeOut(duration: 0.18), value: showingAppearancePicker)
        .contentShape(shape)
        .onHover { hovering in
            // Don't collapse while the picker overlay is up — the user may
            // be moving the mouse toward a swatch that's offset from the
            // header and onHover fires a false positive.
            if !hovering && !showingAppearancePicker { expanded = false }
        }
        .onChange(of: expanded) { _, isExpanded in
            // Closing the panel closes the picker too.
            if !isExpanded { showingAppearancePicker = false }
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
            HStack {
                sectionLabel("Today", count: nil)
                Spacer()
                Text("\(heatmap.totalToday) events")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .monospacedDigit()
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
        }
    }

    private var heatmapStrip: some View {
        let maxCount = max(heatmap.maxCount, 1)
        let currentHour = Calendar.current.component(.hour, from: Date())

        return HStack(spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                let count = heatmap.hourlyCounts[hour]
                let intensity = Double(count) / Double(maxCount)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        cellColor(intensity: intensity, isCurrent: hour == currentHour)
                    )
                    .frame(height: 22)
                    .overlay(
                        // Thin outline on the "now" cell
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                hour == currentHour ? accent : .clear,
                                lineWidth: 1
                            )
                    )
                    .help(hourTooltip(hour: hour, count: count))
            }
        }
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
        HStack(spacing: 14) {
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

            Spacer()

            statBadge
            customizeButton
            quitButton
        }
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

            soundSection
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
