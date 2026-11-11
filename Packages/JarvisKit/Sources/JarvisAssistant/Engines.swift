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
    /// Промежуточный текст во время речи. Без него модель выдаёт только окончательный
    /// текст (после паузы или отпускания клавиши) и не пересчитывает его на лету.
    public var liveResults: Bool
    /// Редкие слова и фразы, которые модель должна узнавать («Джарвис», «Привет, Джарвис»).
    /// Передаются только локальной модели распознавания на этом Mac.
    public var vocabulary: [String]
    /// Усиливать тихий микрофон (AirPods и т.п.) перед распознаванием.
    public var automaticGain: Bool

    public init(
        locale: Locale,
        inputDeviceUID: String? = nil,
        sensitivity: Double = 0.5,
        continuous: Bool = false,
        modelPreference: RecognitionModelPreference = .automatic,
        liveResults: Bool = true,
        vocabulary: [String] = [],
        automaticGain: Bool = true
    ) {
        self.locale = locale
        self.inputDeviceUID = inputDeviceUID
        self.sensitivity = sensitivity
        self.continuous = continuous
        self.modelPreference = modelPreference
        self.liveResults = liveResults
        self.vocabulary = vocabulary
        self.automaticGain = automaticGain
    }
}

/// Событие распознавания речи.
public enum SpeechInputEvent: Sendable, Equatable {
    /// Распознанный фрагмент. Промежуточные (`isFinal == false`) фрагменты заменяют друг друга.
    case transcript(Utterance, isFinal: Bool)
    /// Аудиоустройство изменилось (подключили наушники и т.п.) — захват нужно перезапустить.
    case interrupted
    case failed(FailureCode)
    /// Уровень сигнала микрофона, dBFS (0 — максимум, −60 — очень тихо). Приходит только
    /// при заметном изменении — для индикатора «микрофон слышит».
    case inputLevel(Float)
    /// За первые секунды не пришло ни одного звука: устройство молчит (частая история
    /// с Bluetooth-гарнитурами, если выбрать их в приложении, а не в системе).
    case silentInput
}

/// Подсказка модели распознавания: имя ассистента и фразы-активаторы.
///
/// Слово «Джарвис» — редкое имя собственное: без подсказки модель часто пишет «Джар…»,
/// а потом стирает. Подсказку учитывает классическая модель (`DictationTranscriber`).
public enum RecognitionVocabulary {
    public static let assistantNames = ["Джарвис", "Jarvis"]

    public static func make(wakePhrases: [String]) -> [String] {
        var result: [String] = []
        func add(_ phrase: String) {
            let words = phrase.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            guard !words.isEmpty else { return }
            let capitalized = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            if !result.contains(capitalized) { result.append(capitalized) }
        }
        assistantNames.forEach(add)
        for phrase in wakePhrases {
            add(phrase)
            if let last = phrase.split(whereSeparator: { $0.isWhitespace || $0 == "," }).last {
                add(String(last))
            }
        }
        return result
    }
}

/// Пороги сигнала микрофона.
public enum MicrophoneSignal {
    /// Ниже этого уровня — цифровая тишина (одни нули), а не тихая комната
    /// (у настоящего микрофона шум не опускается ниже примерно −90 dBFS).
    public static let digitalSilence: Float = -120
    /// Сколько ждать хоть какой-то звук после включения микрофона.
    public static let silenceCheckDelay: Duration = .seconds(3)
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
