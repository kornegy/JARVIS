import AppKit
import JarvisAssistant

/// Короткие системные звуки: «слушаю», «принял», «отменено», «ошибка».
@MainActor
public final class SystemFeedbackSounds: FeedbackSounds {
    public init() {}

    public func play(_ cue: SoundCue) {
        NSSound(named: NSSound.Name(Self.soundName(for: cue)))?.play()
    }

    static func soundName(for cue: SoundCue) -> String {
        switch cue {
        case .listening: "Tink"
        case .done: "Pop"
        case .cancelled: "Bottle"
        case .failure: "Basso"
        }
    }
}
