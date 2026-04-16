import AppKit
import Carbon

/// Registers global keyboard shortcuts that work even when another app
/// is focused. Uses `NSEvent.addGlobalMonitorForEvents` for modifier+key
/// combos. Since our NSPanel has `canBecomeKey: false`, normal
/// keyboardShortcut modifiers don't work — we need global monitoring.
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

    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        // Global monitor — fires when another app is focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKey(event)
            }
        }

        // Local monitor — fires when our own app is focused (rare,
        // but covers the case where the panel somehow gets focus)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handleKey(event)
            }
            return event
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
