import Foundation

/// Характер ассистента (0…1). Значения приходят из настроек «Личность».
public struct Personality: Sendable, Equatable {
    /// 0 — без шуток, 1 — шутит часто.
    public var humor: Double
    /// 0 — предельно кратко, 1 — развёрнуто.
    public var verbosity: Double
    /// 0 — на «ты», 1 — на «вы» и официально.
    public var formality: Double

    public init(humor: Double = 0.6, verbosity: Double = 0.35, formality: Double = 0.2) {
        self.humor = humor
        self.verbosity = verbosity
        self.formality = formality
    }

    var isBrief: Bool { verbosity < 0.3 }
    var isFormal: Bool { formality >= 0.6 }
    /// Вероятность добавить шутку к ответу.
    var quipProbability: Double { min(max(humor, 0), 1) * 0.6 }
}

/// Язык ответов. Следует за языком распознавания речи.
public enum ResponseLanguage: Sendable, Equatable {
    case russian
    case english

    public init(locale: Locale) {
        self = locale.language.languageCode?.identifier == "en" ? .english : .russian
    }
}

/// Детерминированный генератор случайных чисел (SplitMix64) — для воспроизводимых тестов.
public struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Составляет ответы с учётом характера: дружелюбно, иногда с иронией, коротко,
/// когда нужно. Шутки — короткие и необязательные; на `humor = 0` их нет совсем.
public struct ResponseComposer {
    public var personality: Personality
    public var language: ResponseLanguage
    private var random: AnyRandomGenerator

    public init(
        personality: Personality = Personality(),
        language: ResponseLanguage = .russian,
        random: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.personality = personality
        self.language = language
        self.random = AnyRandomGenerator(base: random)
    }

    /// Ответ на намерение. `value` — результат инструмента (например, «14:35»).
    public mutating func reply(to intent: Intent, value: String? = nil) -> String {
        let lines = language == .english ? EnglishReplies.lines(for: intent) : RussianReplies.lines(for: intent)
        guard !lines.isEmpty else { return "" }

        let pool: [String]
        if personality.isBrief, !lines.brief.isEmpty {
            pool = lines.brief
        } else if personality.isFormal, !lines.formal.isEmpty {
            pool = lines.formal
        } else {
            pool = lines.casual
        }
        var text = pick(pool)
        if let value {
            text = text.replacingOccurrences(of: "{value}", with: value)
        }
        if case .notYetSupported(let feature) = intent {
            let name = language == .english ? EnglishReplies.featureName(feature) : RussianReplies.featureName(feature)
            text = text.replacingOccurrences(of: "{feature}", with: name)
        }
        if !personality.isBrief, !lines.quips.isEmpty, chance(personality.quipProbability) {
            text += " " + pick(lines.quips)
        }
        return text
    }

    private mutating func pick(_ options: [String]) -> String {
        guard !options.isEmpty else { return "" }
        let index = Int.random(in: 0..<options.count, using: &random)
        return options[index]
    }

    private mutating func chance(_ probability: Double) -> Bool {
        guard probability > 0 else { return false }
        return Double.random(in: 0..<1, using: &random) < probability
    }
}

/// Обёртка: позволяет хранить любой генератор и передавать его в `random(using:)`.
struct AnyRandomGenerator: RandomNumberGenerator {
    var base: any RandomNumberGenerator

    mutating func next() -> UInt64 {
        base.next()
    }
}

/// Набор вариантов ответа на одно намерение.
struct ReplyLines {
    var casual: [String]
    var formal: [String] = []
    var brief: [String] = []
    var quips: [String] = []

    var isEmpty: Bool { casual.isEmpty && formal.isEmpty && brief.isEmpty }

    static let none = ReplyLines(casual: [])
}

enum RussianReplies {
    static func lines(for intent: Intent) -> ReplyLines {
        switch intent {
        case .empty:
            return .none
        case .greeting:
            return ReplyLines(
                casual: ["Привет! Чем займёмся?", "Привет. Я на связи.", "Здорово! Что нужно?"],
                formal: ["Здравствуйте! Чем могу помочь?"],
                brief: ["Привет."],
                quips: ["Надеюсь, сегодня без срочных созвонов.", "Кофе уже был?"]
            )
        case .thanks:
            return ReplyLines(
                casual: ["Всегда пожалуйста.", "Обращайся!", "Не за что."],
                formal: ["Всегда рад помочь."],
                brief: ["Пожалуйста."],
                quips: ["Это моя работа. Ну, почти единственная пока."]
            )
        case .capabilities:
            return ReplyLines(
                casual: ["Пока я умею немного: подскажу время и дату, поставлю микрофон на паузу, включу приватный режим и выключусь по команде. Приложения, файлы и настройки Mac — уже в следующей версии."],
                formal: ["Сейчас я могу подсказать время и дату, поставить микрофон на паузу, включить приватный режим и выключиться по команде. Управление приложениями, файлами и настройками Mac появится в следующей версии."],
                brief: ["Время, дата, пауза микрофона, приватный режим. Остальное — скоро."]
            )
        case .cancel:
            return ReplyLines(
                casual: ["Хорошо, отменяю.", "Окей, забыли."],
                formal: ["Хорошо, отменяю."],
                brief: ["Отменено."]
            )
        case .currentTime:
            return ReplyLines(
                casual: ["Сейчас {value}."],
                brief: ["{value}."],
                quips: ["Самое время для кофе.", "Успеваем всё. Наверное."]
            )
        case .currentDate:
            return ReplyLines(
                casual: ["Сегодня {value}."],
                brief: ["{value}."],
                quips: ["Отличный день, чтобы что-нибудь доделать."]
            )
        case .disableAssistant:
            return ReplyLines(
                casual: ["Выключаюсь. Если что — я в строке меню.", "Ухожу в спящий режим. Зови, если что."],
                formal: ["Выключаюсь. Я в строке меню, если понадоблюсь."],
                brief: ["Выключаюсь."]
            )
        case .pauseMicrophone:
            return ReplyLines(
                casual: ["Ставлю микрофон на паузу.", "Всё, не слушаю."],
                formal: ["Ставлю микрофон на паузу."],
                brief: ["Пауза."]
            )
        case .setPrivacyMode(let enabled):
            return enabled
                ? ReplyLines(casual: ["Приватный режим включён: никакой сети."], brief: ["Приватный режим включён."], quips: ["Тсс."])
                : ReplyLines(casual: ["Приватный режим выключен."], brief: ["Приватный режим выключен."])
        case .notYetSupported:
            return ReplyLines(
                casual: ["{feature} я научусь в следующей версии."],
                brief: ["Пока не умею."],
                quips: ["Уже тренируюсь.", "Обещаю, это ненадолго."]
            )
        case .unknown:
            return ReplyLines(
                casual: ["Пока не понимаю такую команду. Скажи «что ты умеешь» — расскажу, что могу."],
                formal: ["Пока не понимаю такую команду. Скажите «что ты умеешь», и я расскажу, что могу."],
                brief: ["Не понял команду."],
                quips: ["Я быстро учусь, честно."]
            )
        }
    }

    static func featureName(_ feature: Feature) -> String {
        switch feature {
        case .apps: "Управлять приложениями"
        case .files: "Работать с файлами"
        case .system: "Управлять настройками Mac"
        case .reminders: "Ставить напоминания"
        case .mail: "Работать с почтой"
        case .calendar: "Смотреть календарь"
        case .web: "Открывать сайты и искать в интернете"
        case .media: "Управлять музыкой"
        }
    }
}

enum EnglishReplies {
    static func lines(for intent: Intent) -> ReplyLines {
        switch intent {
        case .empty:
            return .none
        case .greeting:
            return ReplyLines(
                casual: ["Hey! What are we doing today?", "Hi. I'm here.", "Hello! What do you need?"],
                formal: ["Hello! How can I help?"],
                brief: ["Hi."],
                quips: ["Hopefully no urgent meetings today."]
            )
        case .thanks:
            return ReplyLines(casual: ["Anytime.", "You got it!", "No problem."], formal: ["Always glad to help."], brief: ["Sure."])
        case .capabilities:
            return ReplyLines(
                casual: ["Not much yet: I can tell the time and date, pause the microphone, turn on privacy mode and switch myself off. Apps, files and Mac settings are coming in the next version."],
                brief: ["Time, date, microphone pause, privacy mode. More soon."]
            )
        case .cancel:
            return ReplyLines(casual: ["Okay, cancelled.", "Sure, forget it."], brief: ["Cancelled."])
        case .currentTime:
            return ReplyLines(casual: ["It's {value}."], brief: ["{value}."], quips: ["Perfect time for coffee."])
        case .currentDate:
            return ReplyLines(casual: ["Today is {value}."], brief: ["{value}."])
        case .disableAssistant:
            return ReplyLines(casual: ["Switching off. I'm in the menu bar if you need me."], brief: ["Switching off."])
        case .pauseMicrophone:
            return ReplyLines(casual: ["Pausing the microphone."], brief: ["Paused."])
        case .setPrivacyMode(let enabled):
            return ReplyLines(casual: [enabled ? "Privacy mode is on: no network." : "Privacy mode is off."])
        case .notYetSupported:
            return ReplyLines(casual: ["I'll learn to {feature} in the next version."], brief: ["Can't do that yet."], quips: ["Already practicing."])
        case .unknown:
            return ReplyLines(
                casual: ["I don't understand that yet. Say \"what can you do\" and I'll tell you."],
                brief: ["Didn't get that."]
            )
        }
    }

    static func featureName(_ feature: Feature) -> String {
        switch feature {
        case .apps: "manage apps"
        case .files: "work with files"
        case .system: "change Mac settings"
        case .reminders: "set reminders"
        case .mail: "work with mail"
        case .calendar: "check your calendar"
        case .web: "open websites and search the web"
        case .media: "control music"
        }
    }
}
