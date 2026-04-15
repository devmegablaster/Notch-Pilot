import Foundation
import Combine
import SwiftUI

/// One moment where the buddy wants to pop out of the notch and say
/// something. Kept deliberately generic — the caller decides the title,
/// subtitle, icon, and duration — so new event sources can reuse the
/// same rendering without touching this file.
struct BuddySpeech: Identifiable, Equatable {
    let id: UUID = UUID()
    let kind: SpeechKind
    let title: String      // short primary line (e.g. project name)
    let subtitle: String   // short secondary line (e.g. "done")
    let icon: String       // SF Symbol
    let tint: Tint
    let duration: TimeInterval

    enum Tint {
        case accent
        case danger
        case neutral
    }

    static func == (lhs: BuddySpeech, rhs: BuddySpeech) -> Bool {
        lhs.id == rhs.id
    }
}

/// What kind of event triggered this speech. Add cases here as new
/// triggers are added (long-running task, first session of the day,
/// dangerous command, etc.). Each new case just needs a matching
/// entry in `BuddyPreferences.SpeechEvent` to get a settings toggle.
enum SpeechKind: String {
    case sessionFinished
}

/// Owns the currently-visible speech and rate-limits new ones. Fires
/// are silently dropped when within the rate-limit window — we'd
/// rather undersell than overwhelm the user.
@MainActor
final class SpeechController: ObservableObject {
    @Published private(set) var current: BuddySpeech?

    /// Minimum gap between two speech appearances across all kinds.
    private let minInterval: TimeInterval = 12
    private var lastSpokeAt: Date?

    /// Dedup set so the same finished-session / same permission UUID
    /// etc. can't fire twice. Keyed by the `key` passed to `speak`.
    private var recentKeys: Set<String> = []

    /// Main entry point. `key` is a caller-supplied stable identifier
    /// so duplicate events for the same thing are suppressed — e.g.
    /// "session-UUID" for a session-finished event.
    func speak(
        kind: SpeechKind,
        key: String,
        title: String,
        subtitle: String,
        icon: String,
        tint: BuddySpeech.Tint,
        duration: TimeInterval = 4.0
    ) {
        let compositeKey = "\(kind.rawValue):\(key)"
        if recentKeys.contains(compositeKey) { return }

        if let last = lastSpokeAt,
           Date().timeIntervalSince(last) < minInterval {
            return
        }

        recentKeys.insert(compositeKey)
        if recentKeys.count > 64 { recentKeys.removeFirst() }

        present(BuddySpeech(
            kind: kind,
            title: title,
            subtitle: subtitle,
            icon: icon,
            tint: tint,
            duration: duration
        ))
    }

    /// Bypass rate-limit + dedup — for the Preview button in settings.
    func preview(
        kind: SpeechKind,
        title: String,
        subtitle: String,
        icon: String,
        tint: BuddySpeech.Tint,
        duration: TimeInterval = 3.2
    ) {
        present(BuddySpeech(
            kind: kind,
            title: title,
            subtitle: subtitle,
            icon: icon,
            tint: tint,
            duration: duration
        ))
    }

    func clear() {
        current = nil
    }

    private func present(_ speech: BuddySpeech) {
        // Wrap state mutations in an explicit withAnimation so the
        // pill scale+opacity transition actually runs. Relying on a
        // `.animation(value:)` modifier on the View wasn't reliable
        // for the if/else branch swap between collapsedPill and
        // speechPill — withAnimation is unambiguous.
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
            current = speech
        }
        lastSpokeAt = Date()

        let id = speech.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(speech.duration * 1_000_000_000)
            )
            guard let self else { return }
            if self.current?.id == id {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                    self.current = nil
                }
            }
        }
    }
}
