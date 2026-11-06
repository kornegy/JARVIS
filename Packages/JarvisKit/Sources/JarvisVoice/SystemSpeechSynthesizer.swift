import AVFoundation
import Foundation
import JarvisAssistant

/// Голос, доступный для ответов.
public struct VoiceOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
}

/// Ответы голосом через `AVSpeechSynthesizer` — синтез на устройстве, без сети.
@MainActor
public final class SystemSpeechSynthesizer: SpeechOutputEngine {
    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SynthesizerDelegate()

    public init() {
        synthesizer.delegate = delegate
    }

    public func speak(_ text: String, settings: SpeechOutputSettings) async {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: settings)
        utterance.rate = Self.rate(for: settings.rate)
        utterance.volume = Float(min(max(settings.volume, 0), 1))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.begin(continuation)
            synthesizer.speak(utterance)
        }
    }

    public func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Голоса для языка; улучшенные и премиальные — первыми.
    public static func voices(for locale: Locale) -> [VoiceOption] {
        let language = locale.language.languageCode?.identifier ?? "ru"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name < rhs.name
            }
            .map { VoiceOption(id: $0.identifier, name: "\($0.name)\(qualitySuffix($0.quality))") }
    }

    /// Скорость 0…1 из настроек → скорость `AVSpeechUtterance` (0,5 — обычная речь).
    static func rate(for value: Double) -> Float {
        let clamped = Float(min(max(value, 0), 1))
        return 0.35 + 0.3 * clamped
    }

    private static func voice(for settings: SpeechOutputSettings) -> AVSpeechSynthesisVoice? {
        if let identifier = settings.voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: settings.locale.identifier(.bcp47))
    }

    private static func qualitySuffix(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: " (премиум)"
        case .enhanced: " (улучшенный)"
        default: ""
        }
    }
}

/// Сообщает, когда фраза договорена или прервана.
private final class SynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func begin(_ newContinuation: CheckedContinuation<Void, Never>) {
        let previous = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let previous = continuation
            continuation = newContinuation
            return previous
        }
        previous?.resume()
    }

    private func finish() {
        let current = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let current = continuation
            continuation = nil
            return current
        }
        current?.resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish()
    }
}
