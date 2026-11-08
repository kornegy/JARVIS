import Foundation
import JarvisCore

/// Все настройки JARVIS. Хранятся в `settings.json` (см. `SettingsStore`).
///
/// Правила совместимости:
/// * у каждого поля есть значение по умолчанию; если поля нет в файле (файл записан более
///   старой версией), берётся значение по умолчанию — поэтому **добавление** полей не требует
///   миграции;
/// * переименование/удаление полей или смена смысла — повышение `currentSchemaVersion`
///   и шаг миграции в `SettingsMigrator`.
///
/// Значения по умолчанию выбраны в пользу приватности (docs/Privacy.md): AI — только локально,
/// облако выключено, журнал — минимальный, микрофон — только по Push-to-Talk.
public struct JarvisSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion = JarvisSettings.currentSchemaVersion
    public var general = GeneralSettings()
    public var voice = VoiceSettings()
    public var ai = AISettings()
    public var privacy = PrivacySettings()
    public var confirmations = ConfirmationSettings()
    public var personality = PersonalitySettings()

    public init() {}

    public static let defaults = JarvisSettings()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, general, voice, ai, privacy, confirmations, personality
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? schemaVersion
        general = try container.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? general
        voice = try container.decodeIfPresent(VoiceSettings.self, forKey: .voice) ?? voice
        ai = try container.decodeIfPresent(AISettings.self, forKey: .ai) ?? ai
        privacy = try container.decodeIfPresent(PrivacySettings.self, forKey: .privacy) ?? privacy
        confirmations = try container.decodeIfPresent(ConfirmationSettings.self, forKey: .confirmations) ?? confirmations
        personality = try container.decodeIfPresent(PersonalitySettings.self, forKey: .personality) ?? personality
    }

    /// Приводит значения к допустимым диапазонам (например, после ручной правки файла).
    public func normalized() -> JarvisSettings {
        var copy = self
        copy.general.assistantName = GeneralSettings.normalizedName(general.assistantName)
        copy.voice.microphoneSensitivity = voice.microphoneSensitivity.clamped(to: 0...1)
        copy.voice.endOfSpeechSilenceSeconds = voice.endOfSpeechSilenceSeconds.clamped(to: 0.5...3)
        copy.voice.speechRate = voice.speechRate.clamped(to: 0...1)
        copy.voice.speechVolume = voice.speechVolume.clamped(to: 0...1)
        copy.voice.wakePhrases = voice.wakePhrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if copy.voice.wakePhrases.isEmpty { copy.voice.wakePhrases = VoiceSettings().wakePhrases }
        copy.privacy.auditRetentionDays = AuditLog.clampRetention(privacy.auditRetentionDays)
        copy.privacy.conversationContextMinutes = min(max(privacy.conversationContextMinutes, 0), 30)
        copy.personality.humor = personality.humor.clamped(to: 0...1)
        copy.personality.verbosity = personality.verbosity.clamped(to: 0...1)
        copy.personality.formality = personality.formality.clamped(to: 0...1)
        return copy
    }
}

// MARK: - Разделы

public struct GeneralSettings: Codable, Equatable, Sendable {
    public static let maxNameLength = 32

    /// Имя ассистента в ответах и интерфейсе.
    public var assistantName = "Джарвис"
    /// Показывать мини-окно при запуске приложения.
    public var showMainWindowAtLaunch = true
    /// Где искать по команде «найди в интернете». Поиск открывается в браузере пользователя.
    public var searchEngine: SearchEngine = .google

    public init() {}

    enum CodingKeys: String, CodingKey { case assistantName, showMainWindowAtLaunch, searchEngine }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assistantName = try container.decodeIfPresent(String.self, forKey: .assistantName) ?? assistantName
        showMainWindowAtLaunch = try container.decodeIfPresent(Bool.self, forKey: .showMainWindowAtLaunch) ?? showMainWindowAtLaunch
        searchEngine = (try? container.decodeIfPresent(SearchEngine.self, forKey: .searchEngine)) ?? searchEngine
    }

    static func normalizedName(_ name: String) -> String {
        let trimmed = name
            .filter { !$0.isNewline }
            .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return GeneralSettings().assistantName }
        return String(trimmed.prefix(maxNameLength))
    }
}

/// Поисковая система для «найди в интернете».
public enum SearchEngine: String, Codable, Sendable, CaseIterable {
    case google
    case yandex
    case duckduckgo
    case bing

    public var displayName: String {
        switch self {
        case .google: "Google"
        case .yandex: "Яндекс"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        }
    }
}

/// Горячая клавиша Push-to-Talk: удерживайте и говорите.
public enum PushToTalkShortcut: String, Codable, Sendable, CaseIterable {
    case controlOptionSpace
    case optionSpace
    case shiftOptionSpace
    case commandOptionJ

    public var displayName: String {
        switch self {
        case .controlOptionSpace: "⌃⌥ Пробел"
        case .optionSpace: "⌥ Пробел"
        case .shiftOptionSpace: "⇧⌥ Пробел"
        case .commandOptionJ: "⌘⌥ J"
        }
    }
}

/// Какую модель распознавания Apple предпочитать (обе работают только на устройстве).
public enum RecognitionModelPreference: String, Codable, Sendable, CaseIterable {
    /// Классическая модель (её можно подсказать: она лучше узнаёт «Джарвис» и фразы-активаторы),
    /// если поддерживает язык, иначе новая.
    case automatic
    /// Классическая модель системной диктовки (`DictationTranscriber`).
    case dictation
    /// Новая модель Apple (`SpeechTranscriber`).
    case modern

    public var displayName: String {
        switch self {
        case .automatic: "Автоматически"
        case .dictation: "Классическая (системная диктовка)"
        case .modern: "Новая модель Apple"
        }
    }
}

public struct VoiceSettings: Codable, Equatable, Sendable {
    /// Языки, для которых есть правила разбора команд и ответы.
    public static let supportedRecognitionLocales = ["ru_RU", "en_US"]

    /// По умолчанию — Push-to-Talk: постоянное прослушивание включается осознанно.
    public var listeningMode: ListeningMode = .pushToTalk
    /// Фразы-активаторы (сравниваются без учёта регистра и пунктуации).
    public var wakePhrases = ["привет джарвис", "hey jarvis"]
    /// Язык распознавания (идентификатор локали).
    public var recognitionLocale = "ru_RU"
    /// UID аудиоустройства ввода; `nil` — системный микрофон по умолчанию.
    public var inputDeviceUID: String?
    /// Чувствительность микрофона 0…1: выше — слышит тише сказанное (детектор речи «мягче»,
    /// порог уровня сигнала ниже).
    public var microphoneSensitivity = 0.5
    /// Пауза, после которой фраза считается законченной, секунд.
    public var endOfSpeechSilenceSeconds = 1.0
    /// Идентификатор голоса TTS; `nil` — системный голос для языка.
    public var voiceIdentifier: String?
    /// Скорость речи 0…1.
    public var speechRate = 0.5
    /// Громкость речи 0…1.
    public var speechVolume = 1.0
    /// Отвечать голосом (на голосовые команды). Текст ответа показывается всегда.
    public var speakResponses = true
    /// Короткие звуки начала и конца прослушивания.
    public var playSounds = true
    /// Горячая клавиша Push-to-Talk.
    public var pushToTalkShortcut: PushToTalkShortcut = .controlOptionSpace
    /// Предпочитаемая модель распознавания.
    public var recognitionModel: RecognitionModelPreference = .automatic
    /// Показывать текст во время речи. Выключение снижает нагрузку: модель не
    /// пересчитывает текст на лету, команда появляется после паузы или отпускания клавиши.
    public var showLiveTranscript = true
    /// Усиливать тихий микрофон перед распознаванием (микрофон AirPods на Mac очень тихий).
    public var automaticGain = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case listeningMode, wakePhrases, recognitionLocale, inputDeviceUID, microphoneSensitivity
        case endOfSpeechSilenceSeconds, voiceIdentifier, speechRate, speechVolume
        case speakResponses, playSounds, pushToTalkShortcut, recognitionModel, showLiveTranscript, automaticGain
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listeningMode = try container.decodeIfPresent(ListeningMode.self, forKey: .listeningMode) ?? listeningMode
        wakePhrases = try container.decodeIfPresent([String].self, forKey: .wakePhrases) ?? wakePhrases
        recognitionLocale = try container.decodeIfPresent(String.self, forKey: .recognitionLocale) ?? recognitionLocale
        inputDeviceUID = try container.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        microphoneSensitivity = try container.decodeIfPresent(Double.self, forKey: .microphoneSensitivity) ?? microphoneSensitivity
        endOfSpeechSilenceSeconds = try container.decodeIfPresent(Double.self, forKey: .endOfSpeechSilenceSeconds) ?? endOfSpeechSilenceSeconds
        voiceIdentifier = try container.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        speechRate = try container.decodeIfPresent(Double.self, forKey: .speechRate) ?? speechRate
        speechVolume = try container.decodeIfPresent(Double.self, forKey: .speechVolume) ?? speechVolume
        speakResponses = try container.decodeIfPresent(Bool.self, forKey: .speakResponses) ?? speakResponses
        playSounds = try container.decodeIfPresent(Bool.self, forKey: .playSounds) ?? playSounds
        pushToTalkShortcut = try container.decodeIfPresent(PushToTalkShortcut.self, forKey: .pushToTalkShortcut) ?? pushToTalkShortcut
        recognitionModel = try container.decodeIfPresent(RecognitionModelPreference.self, forKey: .recognitionModel) ?? recognitionModel
        showLiveTranscript = try container.decodeIfPresent(Bool.self, forKey: .showLiveTranscript) ?? showLiveTranscript
        automaticGain = try container.decodeIfPresent(Bool.self, forKey: .automaticGain) ?? automaticGain
    }

    /// Локаль распознавания; неизвестное значение заменяется русским.
    public var locale: Locale {
        Locale(identifier: VoiceSettings.supportedRecognitionLocales.contains(recognitionLocale) ? recognitionLocale : "ru_RU")
    }
}

/// Где обрабатывать запросы, которые не покрыты локальными правилами.
public enum AIMode: String, Codable, Sendable, CaseIterable {
    /// Только на Mac. Сеть не используется.
    case local
    /// Облачный провайдер (с согласием).
    case cloud
    /// Локально, облако — только для сложных задач (с согласием).
    case hybrid
}

public enum CloudProvider: String, Codable, Sendable, CaseIterable {
    case none
    case anthropic
    case openAI
}

public enum LocalModelBackend: String, Codable, Sendable, CaseIterable {
    /// Только локальные правила, без языковой модели.
    case rulesOnly
    /// Apple Foundation Models, если доступна для языка; иначе только правила.
    case automatic
    /// OpenAI-совместимый сервер на этом Mac (Ollama, LM Studio).
    case localServer
}

public struct AISettings: Codable, Equatable, Sendable {
    public var mode: AIMode = .local
    public var cloudProvider: CloudProvider = .none
    /// Идентификатор модели облачного провайдера; пусто — модель провайдера по умолчанию.
    public var cloudModel = ""
    public var localBackend: LocalModelBackend = .automatic
    /// Адрес локального сервера. Допускается только `localhost` (проверяется при подключении).
    public var localServerURL = "http://localhost:11434/v1"
    public var localServerModel = ""
    /// Показывать, что именно уйдёт в облако, и спрашивать перед каждым запросом.
    public var askBeforeEachCloudRequest = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, cloudProvider, cloudModel, localBackend, localServerURL, localServerModel, askBeforeEachCloudRequest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(AIMode.self, forKey: .mode) ?? mode
        cloudProvider = try container.decodeIfPresent(CloudProvider.self, forKey: .cloudProvider) ?? cloudProvider
        cloudModel = try container.decodeIfPresent(String.self, forKey: .cloudModel) ?? cloudModel
        localBackend = try container.decodeIfPresent(LocalModelBackend.self, forKey: .localBackend) ?? localBackend
        localServerURL = try container.decodeIfPresent(String.self, forKey: .localServerURL) ?? localServerURL
        localServerModel = try container.decodeIfPresent(String.self, forKey: .localServerModel) ?? localServerModel
        askBeforeEachCloudRequest = try container.decodeIfPresent(Bool.self, forKey: .askBeforeEachCloudRequest) ?? askBeforeEachCloudRequest
    }

    /// Может ли вообще использоваться облако с учётом Privacy Mode.
    /// (Согласие, ключ и наличие сети проверяет AI Layer — Phase 4.)
    public func cloudAllowed(privacyMode: Bool) -> Bool {
        !privacyMode && mode != .local && cloudProvider != .none
    }
}

public struct PrivacySettings: Codable, Equatable, Sendable {
    /// Privacy Mode: запрещена любая сетевая обработка AI и голоса.
    public var privacyMode = false
    public var auditDetail: AuditDetailLevel = .minimal
    public var auditRetentionDays = 30
    /// Разрешено ли JARVIS запоминать предпочтения (память — Phase 4).
    public var personalizationEnabled = true
    /// Сколько минут держать контекст диалога в памяти (только RAM, 0 — не держать).
    public var conversationContextMinutes = 2

    public init() {}

    enum CodingKeys: String, CodingKey {
        case privacyMode, auditDetail, auditRetentionDays, personalizationEnabled, conversationContextMinutes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        privacyMode = try container.decodeIfPresent(Bool.self, forKey: .privacyMode) ?? privacyMode
        auditDetail = try container.decodeIfPresent(AuditDetailLevel.self, forKey: .auditDetail) ?? auditDetail
        auditRetentionDays = try container.decodeIfPresent(Int.self, forKey: .auditRetentionDays) ?? auditRetentionDays
        personalizationEnabled = try container.decodeIfPresent(Bool.self, forKey: .personalizationEnabled) ?? personalizationEnabled
        conversationContextMinutes = try container.decodeIfPresent(Int.self, forKey: .conversationContextMinutes) ?? conversationContextMinutes
    }
}

public struct ConfirmationSettings: Codable, Equatable, Sendable {
    /// Подтверждать действия категории 2. Категория 3 подтверждается всегда — это не настраивается.
    public var confirmConsequentialActions = true
    /// Разрешить подтверждать опасные действия голосом (по умолчанию — только кнопкой/клавишей).
    public var allowVoiceConfirmationForDangerousActions = false

    public init() {}

    enum CodingKeys: String, CodingKey { case confirmConsequentialActions, allowVoiceConfirmationForDangerousActions }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        confirmConsequentialActions = try container.decodeIfPresent(Bool.self, forKey: .confirmConsequentialActions) ?? confirmConsequentialActions
        allowVoiceConfirmationForDangerousActions = try container.decodeIfPresent(Bool.self, forKey: .allowVoiceConfirmationForDangerousActions) ?? allowVoiceConfirmationForDangerousActions
    }
}

public struct PersonalitySettings: Codable, Equatable, Sendable {
    /// 0 — без шуток, 1 — максимум иронии.
    public var humor = 0.6
    /// 0 — предельно кратко, 1 — развёрнуто.
    public var verbosity = 0.35
    /// 0 — на «ты» и неформально, 1 — официально.
    public var formality = 0.2
    /// Отвечать короче, когда пользователь занят (например, идёт встреча).
    public var briefWhenBusy = true

    public init() {}

    enum CodingKeys: String, CodingKey { case humor, verbosity, formality, briefWhenBusy }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        humor = try container.decodeIfPresent(Double.self, forKey: .humor) ?? humor
        verbosity = try container.decodeIfPresent(Double.self, forKey: .verbosity) ?? verbosity
        formality = try container.decodeIfPresent(Double.self, forKey: .formality) ?? formality
        briefWhenBusy = try container.decodeIfPresent(Bool.self, forKey: .briefWhenBusy) ?? briefWhenBusy
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
