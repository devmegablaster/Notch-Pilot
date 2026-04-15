import SwiftUI

/// Categories of events the buddy can announce out loud. Each has its own
/// toggle in preferences so the user can enable just the noise they want.
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

    private static let styleKey = "notchpilot.style"
    private static let colorKey = "notchpilot.color"
    private static let voiceKey = "notchpilot.voice"
    private static let voiceEventsKey = "notchpilot.voice.events"
    private static let alwaysVisibleKey = "notchpilot.alwaysVisible"

    init() {
        let defaults = UserDefaults.standard
        let storedStyle = defaults.string(forKey: Self.styleKey) ?? ""
        let storedColor = defaults.string(forKey: Self.colorKey) ?? ""
        style = BuddyStyle(rawValue: storedStyle) ?? .eyes
        color = BuddyColor(rawValue: storedColor) ?? .green
        // Voice master defaults off so new users don't get surprised.
        voiceEnabled = defaults.object(forKey: Self.voiceKey) as? Bool ?? false
        alwaysVisible = defaults.object(forKey: Self.alwaysVisibleKey) as? Bool ?? true

        // Load per-event flags; default each to a sensible value.
        let storedEvents = (defaults.object(forKey: Self.voiceEventsKey) as? [String: Bool]) ?? [:]
        var events: [VoiceEvent: Bool] = [:]
        for e in VoiceEvent.allCases {
            // Defaults: permission + danger + finished on, started off.
            let defaultOn: Bool = (e != .started)
            events[e] = storedEvents[e.rawValue] ?? defaultOn
        }
        voiceEvents = events
    }
}
