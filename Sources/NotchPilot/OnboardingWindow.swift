import AppKit
import SwiftUI

/// Full-screen transparent panel used for the first-launch intro.
///
/// Lives at `.screenSaver` level so it sits above the menu bar and dock
/// for the takeover effect, but uses `.nonactivatingPanel` + never
/// becomes key so it doesn't steal focus from whatever the user is in.
final class OnboardingWindow: NSPanel {

    init(
        preferences: BuddyPreferences,
        notchWidth: CGFloat,
        notchHeight: CGFloat,
        onComplete: @escaping () -> Void
    ) {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .screenSaver
        self.isMovable = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = false
        self.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary,
        ]
        self.alphaValue = 1

        let view = OnboardingView(
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            onComplete: onComplete
        )
        .environmentObject(preferences)

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: screenFrame.size)
        hosting.autoresizingMask = [.width, .height]
        self.contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
