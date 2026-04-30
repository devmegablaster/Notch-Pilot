import SwiftUI
import ServiceManagement
import CoreGraphics

/// Where the notch overlay lives on its host screen. `topCenter` on the
/// primary notched display is the original behavior — sits in the
/// hardware notch. The other zones float as a rounded pill flush with
/// the top edge. Five zones evenly distribute the pill across the top
/// of the screen so users on wide displays can land it where it doesn't
/// fight whatever they happen to have in the menu bar.
enum NotchPosition: String, CaseIterable, Identifiable {
    case topLeft
    case topMidLeft
    case topCenter
    case topMidRight
    case topRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft:     return "Top left"
        case .topMidLeft:  return "Top mid-left"
        case .topCenter:   return "Top center"
        case .topMidRight: return "Top mid-right"
        case .topRight:    return "Top right"
        }
    }

    /// Where the pill's center should sit, expressed as a fraction of
    /// the host screen's width. 0 = left edge, 1 = right edge. Used by
    /// the frame helpers so adding a new zone is just one entry here.
    var horizontalAnchor: CGFloat {
        switch self {
        case .topLeft:     return 0.0
        case .topMidLeft:  return 0.25
        case .topCenter:   return 0.5
        case .topMidRight: return 0.75
        case .topRight:    return 1.0
        }
    }
}

/// Categories of events the buddy can announce out loud. Each has its own
/// toggle in preferences so the user can enable just the noise they want.
/// Events that can cause the buddy to pop out of the notch and say
/// something. Each case has its own preference toggle so users can
/// mute individual triggers. Add cases here as new speech kinds are
/// added to `SpeechKind`.
enum SpeechEvent: String, CaseIterable, Identifiable {
    case sessionFinished

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessionFinished: return "Session finished"
        }
    }

    var icon: String {
        switch self {
        case .sessionFinished: return "checkmark.circle.fill"
        }
    }
}

enum VoiceEvent: String, CaseIterable, Identifiable {
    case permission
    case danger
    case started
    case finished

    var id: String { rawValue }

    var label: String {
        switch self {
        case .permission: return "Permission needed"
        case .danger:     return "Dangerous command"
        case .started:    return "Session started"
        case .finished:   return "Session finished"
        }
    }

    var icon: String {
        switch self {
        case .permission: return "hand.raised.fill"
        case .danger:     return "exclamationmark.triangle.fill"
        case .started:    return "play.circle.fill"
        case .finished:   return "checkmark.circle.fill"
        }
    }
}

/// User-pickable appearance + sound settings for the buddy, persisted to
/// `UserDefaults`. Injected into the SwiftUI view tree via `.environmentObject`.
@MainActor
final class BuddyPreferences: ObservableObject {
    @Published var style: BuddyStyle {
        didSet {
            UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey)
        }
    }

    @Published var color: BuddyColor {
        didSet {
            UserDefaults.standard.set(color.rawValue, forKey: Self.colorKey)
        }
    }

    /// When true, the buddy stays pinned to the notch at all times,
    /// even with no active Claude session. Off by default — the default
    /// behavior is to fade out 10s after activity ends and re-appear on
    /// the next session (or on hover).
    @Published var alwaysVisible: Bool {
        didSet {
            UserDefaults.standard.set(alwaysVisible, forKey: Self.alwaysVisibleKey)
        }
    }

    /// When true, the app registers itself as a macOS login item via
    /// SMAppService so it auto-launches on every login. Defaults to
    /// true — the natural expectation for a menu-bar utility.
    @Published var startAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(startAtLogin, forKey: Self.startAtLoginKey)
            applyStartAtLogin()
        }
    }

    /// When true, the buddy fires a subtle haptic tick through the
    /// trackpad whenever the notch panel opens or closes. Only works
    /// on devices with a Force Touch trackpad; external mouse/keyboard
    /// users get nothing. Defaults on.
    @Published var hapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hapticsEnabled, forKey: Self.hapticsKey)
        }
    }

    /// When true, the notch hides when any app is in fullscreen mode.
    /// Defaults true — fullscreen covers the notch area anyway.
    @Published var hideInFullscreen: Bool {
        didSet {
            UserDefaults.standard.set(hideInFullscreen, forKey: Self.hideFullscreenKey)
        }
    }

    /// When true, permission prompts are suppressed in the notch if the
    /// terminal running the session is the frontmost app. The user can
    /// answer directly in the terminal. Defaults false (always show).
    @Published var suppressPermissionWhenFocused: Bool {
        didSet {
            UserDefaults.standard.set(suppressPermissionWhenFocused, forKey: Self.suppressPermKey)
        }
    }

    /// Master toggle for speech — when off, no event can trigger a
    /// buddy pop-out regardless of per-event flags. Defaults on.
    @Published var speechEnabled: Bool {
        didSet {
            UserDefaults.standard.set(speechEnabled, forKey: Self.speechKey)
        }
    }


    /// Per-event speech toggles.
    @Published var speechEvents: [SpeechEvent: Bool] {
        didSet {
            let raw = speechEvents.reduce(into: [String: Bool]()) { acc, pair in
                acc[pair.key.rawValue] = pair.value
            }
            UserDefaults.standard.set(raw, forKey: Self.speechEventsKey)
        }
    }

    func speechAllows(_ event: SpeechEvent) -> Bool {
        speechEnabled && (speechEvents[event] ?? true)
    }

    func setSpeechEvent(_ event: SpeechEvent, _ enabled: Bool) {
        var copy = speechEvents
        copy[event] = enabled
        speechEvents = copy
    }

    /// Pushes the current `startAtLogin` value to macOS via SMAppService.
    /// Idempotent: safe to call repeatedly. Logs and continues on
    /// failure (e.g. when running from a non-bundled `swift run` build
    /// where the main app service isn't resolvable).
    func applyStartAtLogin() {
        let service = SMAppService.mainApp
        do {
            if startAtLogin {
                if service.status != .enabled {
                    try service.register()
                    print("[NotchPilot] Registered as login item")
                }
            } else {
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                    print("[NotchPilot] Unregistered from login items")
                }
            }
        } catch {
            print("[NotchPilot] start-at-login update failed: \(error)")
        }
    }

    /// Master toggle. If off, NOTHING speaks regardless of per-event flags.
    @Published var voiceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(voiceEnabled, forKey: Self.voiceKey)
        }
    }

    /// Per-event toggles. All default true — user can selectively mute.
    @Published var voiceEvents: [VoiceEvent: Bool] {
        didSet {
            let raw = voiceEvents.reduce(into: [String: Bool]()) { acc, pair in
                acc[pair.key.rawValue] = pair.value
            }
            UserDefaults.standard.set(raw, forKey: Self.voiceEventsKey)
        }
    }

    /// Returns true iff the master toggle is on AND this specific event's
    /// flag is on. Use this at every `speak` call site.
    func voiceAllows(_ event: VoiceEvent) -> Bool {
        voiceEnabled && (voiceEvents[event] ?? true)
    }

    func setVoiceEvent(_ event: VoiceEvent, _ enabled: Bool) {
        var copy = voiceEvents
        copy[event] = enabled
        voiceEvents = copy
    }

    /// Snap zone the notch lives in on its host screen. Updated by the
    /// drag-to-move interaction in NotchWindow and by the "Reset
    /// position" settings button.
    @Published var notchPosition: NotchPosition {
        didSet {
            UserDefaults.standard.set(notchPosition.rawValue, forKey: Self.notchPositionKey)
        }
    }

    /// Display the notch is currently shown on. `nil` means "follow the
    /// system primary screen." Persisted as an Int because UserDefaults
    /// has no native UInt32 setter; widened for safety.
    @Published var notchScreenID: CGDirectDisplayID? {
        didSet {
            if let id = notchScreenID {
                UserDefaults.standard.set(Int(id), forKey: Self.notchScreenIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.notchScreenIDKey)
            }
        }
    }

    private static let styleKey = "notchpilot.style"
    private static let colorKey = "notchpilot.color"
    private static let voiceKey = "notchpilot.voice"
    private static let voiceEventsKey = "notchpilot.voice.events"
    private static let alwaysVisibleKey = "notchpilot.alwaysVisible"
    private static let startAtLoginKey = "notchpilot.startAtLogin"
    private static let hapticsKey = "notchpilot.haptics"
    private static let speechKey = "notchpilot.speech"
    private static let speechEventsKey = "notchpilot.speech.events"
    private static let suppressPermKey = "notchpilot.suppressPermissionWhenFocused"
    private static let hideFullscreenKey = "notchpilot.hideInFullscreen"
    private static let notchPositionKey = "notchpilot.notchPosition"
    private static let notchScreenIDKey = "notchpilot.notchScreenID"

    init() {
        let defaults = UserDefaults.standard
        let storedStyle = defaults.string(forKey: Self.styleKey) ?? ""
        let storedColor = defaults.string(forKey: Self.colorKey) ?? ""
        style = BuddyStyle(rawValue: storedStyle) ?? .eyes
        color = BuddyColor(rawValue: storedColor) ?? .green
        // Voice master defaults off so new users don't get surprised.
        voiceEnabled = defaults.object(forKey: Self.voiceKey) as? Bool ?? false
        alwaysVisible = defaults.object(forKey: Self.alwaysVisibleKey) as? Bool ?? true
        startAtLogin = defaults.object(forKey: Self.startAtLoginKey) as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: Self.hapticsKey) as? Bool ?? true
        speechEnabled = defaults.object(forKey: Self.speechKey) as? Bool ?? true
        suppressPermissionWhenFocused = defaults.object(forKey: Self.suppressPermKey) as? Bool ?? false
        hideInFullscreen = defaults.object(forKey: Self.hideFullscreenKey) as? Bool ?? true

        let storedPosition = defaults.string(forKey: Self.notchPositionKey) ?? ""
        notchPosition = NotchPosition(rawValue: storedPosition) ?? .topCenter
        if let storedScreen = defaults.object(forKey: Self.notchScreenIDKey) as? Int {
            notchScreenID = CGDirectDisplayID(storedScreen)
        } else {
            notchScreenID = nil
        }

        let storedSpeechEvents = (defaults.object(forKey: Self.speechEventsKey) as? [String: Bool]) ?? [:]
        var se: [SpeechEvent: Bool] = [:]
        for event in SpeechEvent.allCases {
            se[event] = storedSpeechEvents[event.rawValue] ?? true
        }
        speechEvents = se

        // Load per-event flags; default each to a sensible value.
        let storedEvents = (defaults.object(forKey: Self.voiceEventsKey) as? [String: Bool]) ?? [:]
        var events: [VoiceEvent: Bool] = [:]
        for e in VoiceEvent.allCases {
            // Defaults: permission + danger + finished on, started off.
            let defaultOn: Bool = (e != .started)
            events[e] = storedEvents[e.rawValue] ?? defaultOn
        }
        voiceEvents = events

        // Reconcile login-item state with the stored pref. didSet
        // doesn't fire from init in Swift, so on first launch we need
        // to manually push the default `true` into SMAppService to
        // actually register the app. Idempotent on subsequent launches.
        applyStartAtLogin()
    }
}
