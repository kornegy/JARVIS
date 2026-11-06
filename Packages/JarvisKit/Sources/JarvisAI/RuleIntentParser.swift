/// Возможность, которой JARVIS пока не умеет, но команду для неё уже узнаёт.
/// Нужна, чтобы честно ответить «научусь в следующей версии», а не «не понял».
public enum Feature: String, Sendable, CaseIterable {
    case apps
    case files
    case system
    case reminders
    case mail
    case calendar
    case web
    case media
}

/// Что хочет пользователь.
public enum Intent: Sendable, Equatable {
    case empty
    case greeting
    case thanks
    case capabilities
    case cancel
    case currentTime
    case currentDate
    case disableAssistant
    case pauseMicrophone
    case setPrivacyMode(Bool)
    case notYetSupported(Feature)
    case unknown
}

/// Локальный разбор команд по правилам (русский и английский).
///
/// Детерминированный и мгновенный: не нужен ни интернет, ни языковая модель. Обрабатывает
/// частые простые команды; то, что не распознано, в будущем (Phase 4) уйдёт в LLM.
public struct RuleIntentParser: Sendable {
    public init() {}

    public func parse(_ text: String) -> Intent {
        let words = TextNormalizer.words(text)
        guard !words.isEmpty else { return .empty }
        let sentence = Sentence(words: words)

        if sentence.hasWord(startingWith: Lexicon.privacy) {
            if sentence.hasWord(startingWith: Lexicon.turnOff) || sentence.hasWord(in: ["off", "disable"]) {
                return .setPrivacyMode(false)
            }
            if sentence.hasWord(startingWith: Lexicon.turnOn) || sentence.hasWord(in: ["on", "enable", "activate"]) {
                return .setPrivacyMode(true)
            }
        }
        if sentence.contains(any: Lexicon.disableAssistant) || sentence.isExactly(any: Lexicon.disableAssistantExact) {
            return .disableAssistant
        }
        if sentence.contains(any: Lexicon.pauseMicrophone) || sentence.isExactly(any: Lexicon.pauseMicrophoneExact) {
            return .pauseMicrophone
        }
        if sentence.isExactly(any: Lexicon.cancel) { return .cancel }
        if sentence.contains(any: Lexicon.time) || sentence.isExactly(any: Lexicon.timeExact) { return .currentTime }
        if sentence.contains(any: Lexicon.date) { return .currentDate }
        if sentence.contains(any: Lexicon.capabilities) || sentence.isExactly(any: Lexicon.capabilitiesExact) {
            return .capabilities
        }
        if let feature = Self.feature(in: sentence) { return .notYetSupported(feature) }
        if sentence.contains(any: Lexicon.thanks) { return .thanks }
        if Self.isGreeting(sentence) { return .greeting }
        return .unknown
    }

    private static func feature(in sentence: Sentence) -> Feature? {
        if sentence.hasWord(startingWith: Lexicon.web) { return .web }
        if sentence.hasWord(startingWith: Lexicon.mail) { return .mail }
        if sentence.hasWord(startingWith: Lexicon.calendar) || sentence.contains(any: ["планы на"]) { return .calendar }
        if sentence.hasWord(startingWith: Lexicon.reminders) { return .reminders }
        if sentence.hasWord(startingWith: Lexicon.media) { return .media }
        if sentence.hasWord(startingWith: Lexicon.system) || sentence.contains(any: ["wi fi"]) { return .system }
        if sentence.hasWord(startingWith: Lexicon.files) { return .files }
        if sentence.hasWord(startingWith: Lexicon.apps) { return .apps }
        if sentence.hasWord(startingWith: Lexicon.search) { return .files }
        return nil
    }

    private static func isGreeting(_ sentence: Sentence) -> Bool {
        if sentence.contains(any: Lexicon.greetingPhrases) { return true }
        guard let first = sentence.words.first, sentence.words.count <= 3 else { return false }
        return Lexicon.greetingWords.contains(first)
    }
}

/// Нормализованная фраза с удобными проверками по словам.
private struct Sentence {
    let words: [String]
    let padded: String

    init(words: [String]) {
        self.words = words
        self.padded = " " + words.joined(separator: " ") + " "
    }

    /// Содержит одну из фраз целиком (по границам слов).
    func contains(any phrases: [String]) -> Bool {
        phrases.contains { padded.contains(" " + TextNormalizer.normalize($0) + " ") }
    }

    /// Вся фраза совпадает с одной из вариантов.
    func isExactly(any phrases: [String]) -> Bool {
        let whole = words.joined(separator: " ")
        return phrases.contains { TextNormalizer.normalize($0) == whole }
    }

    func hasWord(startingWith prefixes: [String]) -> Bool {
        words.contains { word in prefixes.contains { word.hasPrefix($0) } }
    }

    func hasWord(in set: Set<String>) -> Bool {
        words.contains { set.contains($0) }
    }
}

/// Словарь правил. Фразы пишутся как обычный текст — нормализуются при сравнении.
private enum Lexicon {
    static let privacy = ["приватн", "конфиденциальн", "privacy", "private"]
    static let turnOff = ["выключ", "отключ", "деактив"]
    static let turnOn = ["включ", "актив"]

    static let disableAssistant = ["выключись", "отключись", "выключи себя", "отключи себя", "иди спать"]
    static let disableAssistantExact = ["спи", "turn off", "shut down", "go to sleep", "switch off", "turn yourself off"]

    static let pauseMicrophone = [
        "не слушай", "перестань слушать", "хватит слушать", "прекрати слушать",
        "выключи микрофон", "отключи микрофон", "stop listening", "mute the microphone", "mute microphone",
    ]
    static let pauseMicrophoneExact = ["пауза", "mute"]

    static let cancel = [
        "отмена", "отмени", "отменить", "стоп", "ничего", "неважно", "не важно", "забудь", "забей", "проехали",
        "cancel", "never mind", "nevermind", "nothing", "stop",
    ]

    static let time = [
        "который час", "сколько времени", "сколько сейчас времени", "какое сейчас время", "скажи время",
        "текущее время", "what time", "current time", "time is it",
    ]
    static let timeExact = ["время", "time"]

    static let date = [
        "какое сегодня число", "какое число", "какой сегодня день", "какой день недели", "какая сегодня дата",
        "какая дата", "сегодняшняя дата", "what's the date", "what is the date", "what date", "what day is it",
        "today's date", "what day is today",
    ]

    static let capabilities = [
        "что ты умеешь", "что ты можешь", "что умеешь", "что можешь", "твои возможности", "на что ты способен",
        "what can you do", "what do you do", "your capabilities",
    ]
    static let capabilitiesExact = ["помощь", "справка", "help"]

    static let thanks = ["спасибо", "благодарю", "thanks", "thank you", "thx"]

    static let greetingPhrases = ["добрый день", "доброе утро", "добрый вечер", "good morning", "good afternoon", "good evening"]
    static let greetingWords: Set<String> = ["привет", "здравствуй", "здравствуйте", "хай", "салют", "здорово", "hello", "hi", "hey"]

    static let web = ["сайт", "site", "www", "интернет", "internet", "гугл", "google", "яндекс", "yandex", "youtube", "ютуб"]
    static let mail = ["почт", "письм", "писем", "mail", "email", "inbox"]
    static let calendar = ["календар", "запланир", "встреч", "расписан", "calendar", "schedule", "meeting", "agenda"]
    static let reminders = ["напомн", "напоминан", "remind"]
    static let media = ["музык", "песн", "трек", "плейлист", "music", "song", "playlist"]
    static let system = [
        "громк", "громче", "тише", "ярк", "вайфа", "wifi", "блютуз", "bluetooth", "volume", "louder", "quieter",
        "brightness", "буфер", "clipboard",
    ]
    static let files = ["файл", "папк", "документ", "pdf", "скачан", "загрузк", "file", "folder", "document", "download"]
    static let apps = [
        "открой", "откро", "открыть", "запусти", "запуст", "закрой", "закрыть", "заверши", "переключ", "приложен",
        "браузер", "open", "launch", "close", "quit", "switch", "browser",
    ]
    static let search = ["найди", "найти", "поищи", "ищи", "find", "search"]
}
