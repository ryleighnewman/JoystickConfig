import Foundation
import AVFoundation
import GameController
import CoreHaptics

/// Centralized service for non-input feedback when a binding fires:
/// haptic rumble on the controller and spoken phrases through the Mac or
/// controller speaker.
@MainActor
final class FeedbackService {
    static let shared = FeedbackService()

    private let speech = AVSpeechSynthesizer()
    private var hapticEngines: [ObjectIdentifier: CHHapticEngine] = [:]

    private init() {}

    // MARK: - Haptics

    /// Play a short transient haptic on the given controller, if it supports
    /// Core Haptics. Silently no-ops on controllers without haptics.
    func vibrate(controller: GCController, intensity: Float = 0.6, sharpness: Float = 0.5) {
        guard let haptics = controller.haptics else { return }
        let key = ObjectIdentifier(controller)

        let engine: CHHapticEngine
        if let existing = hapticEngines[key] {
            engine = existing
        } else {
            guard let new = haptics.createEngine(withLocality: .default) else { return }
            do {
                try new.start()
            } catch {
                return
            }
            new.resetHandler = { [weak self, weak new] in
                guard let new = new else { return }
                try? new.start()
                _ = self
            }
            new.stoppedHandler = { _ in }
            hapticEngines[key] = new
            engine = new
        }

        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0, min(1, intensity))),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0, min(1, sharpness))),
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Best effort; ignore failures
        }
    }

    /// Tear down haptic engines (called when controllers disconnect or app quits).
    func clearHapticEngines() {
        for engine in hapticEngines.values {
            engine.stop(completionHandler: nil)
        }
        hapticEngines.removeAll()
    }

    // MARK: - Speech

    /// Speak a phrase. The destination decides which audio device to use.
    /// "Mac" plays through whatever audio output the Mac is currently using.
    /// "Controller" routes audio through the controller speaker when one is
    /// connected as an audio output device, otherwise falls back to Mac.
    func speak(_ phrase: String, destination: SpeechDestination = .mac, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        guard !phrase.isEmpty else { return }
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = rate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        // Note: on macOS there is no public API to pin speech to a specific output device.
        // The user can route audio to the controller speaker via System Settings > Sound,
        // and the speech will follow the active output. The destination value is preserved
        // here so future versions can route explicitly when an API becomes available.
        _ = destination
        speech.speak(utterance)
    }

    /// Cancel any ongoing speech.
    func stopSpeaking() {
        speech.stopSpeaking(at: .immediate)
    }
}
