import AppKit
import Carbon

/// Registers global keyboard shortcuts that work even when another app
/// is focused. Uses `NSEvent.addGlobalMonitorForEvents` for modifier+key
/// combos. Since our NSPanel has `canBecomeKey: false`, normal
/// keyboardShortcut modifiers don't work — we need global monitoring.
///
/// Requires Accessibility permissions — on first launch, prompts the
/// user to grant access in System Settings.
@MainActor
final class GlobalHotkeys: ObservableObject {
    /// Fired when the user presses ⌘. (allow)
    var onAllow: (() -> Void)?
    /// Fired when the user presses ⌘, (deny)
    var onDeny: (() -> Void)?
    /// Fired when the user presses ⌘\ (toggle notch)
    var onToggle: (() -> Void)?

    /// Incremented each time ⌘\ is pressed — observed by the view
    /// to toggle its expanded state without needing a direct reference.
    @Published var toggleCount: Int = 0

    /// True when accessibility access is missing — drives an inline
    /// banner in the notch panel.
    @Published var accessibilityMissing = false

    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        if AXIsProcessTrusted() {
            accessibilityMissing = false
        } else {
            // Don't show the macOS system prompt — it's annoying on
            // every update since ad-hoc signing changes the identity.
            // The in-app banner with "Open" button handles this.
            accessibilityMissing = true
            pollForAccessibility()
        }

        setupMonitors()
    }

    private func setupMonitors() {
        // Global monitor — fires when another app is focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKey(event)
            }
        }

        // Local monitor — fires when our own app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKey(event)
            }
            return event
        }
    }

    /// Poll every 2 seconds until accessibility is granted, then
    /// restart the monitors (they silently fail without the permission).
    private func pollForAccessibility() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if AXIsProcessTrusted() {
                    accessibilityMissing = false
                    // Restart monitors now that we have permission
                    stop()
                    setupMonitors()
                    return
                }
            }
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handleKey(_ event: NSEvent) {
        // Only respond to ⌘+key (no other modifiers like shift/ctrl/option)
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.shift),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option)
        else { return }

        switch event.charactersIgnoringModifiers {
        case ".":
            onAllow?()
        case ",":
            onDeny?()
        case "\\":
            onToggle?()
        default:
            break
        }
    }
}
