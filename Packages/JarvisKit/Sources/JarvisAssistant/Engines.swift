import Foundation
import JarvisCore
import JarvisSettings

// Интерфейсы «движков», с которыми работает ассистент. Реализации для macOS — в модуле
// JarvisVoice; в тестах — простые подделки. Благодаря этому вся логика ассистента
// проверяется в CI без микрофона.

/// Состояние системного разрешения.
public enum PermissionState: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
}

/// Готовность модели распознавания речи для языка.
public enum SpeechModelStatus: Sendable, Equatable {
    /// Модель на Mac, можно распознавать без сети.
    case installed
    /// Язык поддерживается, но модель нужно один раз скачать у Apple.
    case needsDownload
    /// Модель скачивается.
    case downloading
    /// Язык не поддерживается для локального распознавания.
    case unsupportedLanguage
}

/// Параметры захвата и распознавания.
public struct SpeechInputConfiguration: Sendable, Equatable {
    public var locale: Locale
    /// UID микрофона; `nil` — системный микрофон по умолчанию.
    public var inputDeviceUID: String?
    /// Чувствительность 0…1: выше — слышит тише сказанное.
    public var sensitivity: Double
    /// Постоянное прослушивание (режим wake word): тишина до распознавания не доходит,
    /// анализ идёт с фоновым приоритетом.
    public var continuous: Bool
    public var modelPreference: RecognitionModelPreference

    public init(
        locale: Locale,
        inputDeviceUID: String? = nil,
        sensitivity: Double = 0.5,
        continuous: Bool = false,
        modelPreference: RecognitionModelPreference = .automatic
    ) {
        self.locale = locale
        self.inputDeviceUID = inputDeviceUID
        self.sensitivity = sensitivity
        self.continuous = continuous
        self.modelPreference = modelPreference
    }
}

/// Событие распознавания речи.
public enum SpeechInputEvent: Sendable, Equatable {
    /// Распознанный фрагмент. Промежуточные (`isFinal == false`) фрагменты заменяют друг друга.
    case transcript(Utterance, isFinal: Bool)
    /// Аудиоустройство изменилось (подключили наушники и т.п.) — захват нужно перезапустить.
    case interrupted
    case failed(FailureCode)
}

/// Ошибки запуска распознавания.
public enum SpeechEngineError: Error, Sendable, Equatable {
    case microphoneUnavailable
    case languageNotSupported
    case modelNotInstalled
    case speechRecognitionNotAuthorized
    case audioEngineFailed
}

/// Захват звука и локальное распознавание речи.
///
/// Реализация обязана распознавать **только на устройстве** (docs/Privacy.md §1).
@MainActor
public protocol SpeechInputEngine: AnyObject {
    /// Идёт ли сейчас захват звука с микрофона.
    var isCapturing: Bool { get }
    /// Какая модель распознавания сейчас работает (для диагностики), `nil` — захвата нет.
    var activeModelName: String? { get }
    func modelStatus(for configuration: SpeechInputConfiguration) async -> SpeechModelStatus
    /// Скачивает системную модель языка у Apple (звук и текст при этом не передаются).
    func downloadModel(for configuration: SpeechInputConfiguration) async throws
    func start(_ configuration: SpeechInputConfiguration) async throws -> AsyncStream<SpeechInputEvent>
    func stop() async
    /// Пропускать к распознаванию весь звук, даже тихий (пока пользователь явно говорит
    /// команду). Без этого в постоянном режиме тишина и тихий фон отсекаются.
    func setForcedListening(_ forced: Bool)
    /// Попросить распознавание выдать окончательный текст по уже услышанному звуку.
    func finalize() async
}

/// Параметры голоса ответа.
public struct SpeechOutputSettings: Sendable, Equatable {
    public var locale: Locale
    public var voiceIdentifier: String?
    /// Скорость 0…1 (0,5 — обычная).
    public var rate: Double
    /// Громкость 0…1.
    public var volume: Double

    public init(locale: Locale, voiceIdentifier: String? = nil, rate: Double = 0.5, volume: Double = 1) {
        self.locale = locale
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
        self.volume = volume
    }
}

/// Синтез речи (ответы голосом).
@MainActor
public protocol SpeechOutputEngine: AnyObject {
    /// Возвращается, когда фраза договорена или прервана.
    func speak(_ text: String, settings: SpeechOutputSettings) async
    func stopSpeaking()
}

/// Системное разрешение (микрофон, распознавание речи).
@MainActor
public protocol PermissionAccess: AnyObject {
    var state: PermissionState { get }
    func request() async -> Bool
}

/// Короткие звуковые сигналы.
public enum SoundCue: Sendable, Equatable {
    case listening
    case done
    case cancelled
    case failure
}

@MainActor
public protocol FeedbackSounds: AnyObject {
    func play(_ cue: SoundCue)
}
