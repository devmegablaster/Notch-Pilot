import Foundation
import AVFoundation

/// Speaks short notifications for key Claude events using the system voice.
///
/// Kept intentionally low-frequency and deduped so the buddy doesn't become
/// a chatterbox. All events check the user's preference before speaking.
@MainActor
final class VoiceAnnouncer {
    static let shared = VoiceAnnouncer()

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenAt: [String: Date] = [:]
    private let minGapBetweenSameMessage: TimeInterval = 4

    private init() {}

    func speak(_ text: String, event: VoiceEvent, prefs: BuddyPreferences) {
        guard prefs.voiceAllows(event) else { return }

        // Debounce: don't repeat the same event-class within a short window.
        let key = event.rawValue
        if let last = lastSpokenAt[key],
           Date().timeIntervalSince(last) < minGapBetweenSameMessage {
            return
        }
        lastSpokenAt[key] = Date()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.85
        if let voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Ava")
            ?? AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
