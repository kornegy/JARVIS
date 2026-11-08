/// Возможность, которой JARVIS пока не умеет, но команду для неё уже узнаёт.
/// Нужна, чтобы честно ответить «научусь в следующей версии», а не «не понял».
public enum Feature: String, Sendable, CaseIterable {
    case files
    case system
    case reminders
    case mail
    case calendar
    case media
    /// Составная команда («открой X и сделай Y») или действие над группой («закрой все приложения»).
    case multiStep
}

/// Куда менять громкость.
public enum VolumeDirection: Sendable, Equatable {
    case up
    case down
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
    /// Открыть приложение (или переключиться на него). Значение — как его назвал пользователь.
    case openApp(String)
    /// Закрыть приложение.
    case quitApp(String)
    /// Открыть сайт: адрес («github.com») или название («ютуб»).
    case openWebsite(String)
    /// Поиск в интернете.
    case webSearch(String)
    /// Громкость 0…100.
    case setVolume(Int)
    case changeVolume(VolumeDirection)
    case setMuted(Bool)
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
        if let intent = Self.volumeIntent(in: sentence) { return intent }
        if sentence.contains(any: Lexicon.time) || sentence.isExactly(any: Lexicon.timeExact) { return .currentTime }
        if sentence.contains(any: Lexicon.date) { return .currentDate }
        if sentence.contains(any: Lexicon.capabilities) || sentence.isExactly(any: Lexicon.capabilitiesExact) {
            return .capabilities
        }
        if let intent = Self.searchIntent(in: sentence) { return intent }
        if let intent = Self.appOrSiteIntent(in: sentence, rawText: text) { return intent }
        if let feature = Self.feature(in: sentence) { return .notYetSupported(feature) }
        if sentence.contains(any: Lexicon.thanks) { return .thanks }
        if Self.isGreeting(sentence) { return .greeting }
        return .unknown
    }

    private static func feature(in sentence: Sentence) -> Feature? {
        if let feature = specificFeature(in: sentence) { return feature }
        if sentence.hasWord(startingWith: Lexicon.search) { return .files }
        return nil
    }

    /// Возможность, явно названная в команде (почта, календарь, файлы…).
    private static func specificFeature(in sentence: Sentence) -> Feature? {
        if sentence.hasWord(startingWith: Lexicon.mail) { return .mail }
        if sentence.hasWord(startingWith: Lexicon.calendar) || sentence.contains(any: ["планы на"]) { return .calendar }
        if sentence.hasWord(startingWith: Lexicon.reminders) { return .reminders }
        if sentence.hasWord(startingWith: Lexicon.media) { return .media }
        if sentence.hasWord(startingWith: Lexicon.system) || sentence.contains(any: ["wi fi"]) { return .system }
        if sentence.hasWord(startingWith: Lexicon.files) { return .files }
        return nil
    }

    // MARK: - Громкость

    private static func volumeIntent(in sentence: Sentence) -> Intent? {
        if sentence.contains(any: Lexicon.mute) { return .setMuted(true) }
        if sentence.contains(any: Lexicon.unmute) { return .setMuted(false) }

        let aboutVolume = sentence.hasWord(startingWith: Lexicon.volume)
        if aboutVolume, let level = sentence.firstNumber ?? specialLevel(in: sentence) {
            return .setVolume(min(max(level, 0), 100))
        }
        if sentence.hasWord(in: Lexicon.louder) || sentence.contains(any: Lexicon.louderPhrases)
            || (aboutVolume && sentence.hasWord(startingWith: Lexicon.increase)) {
            return .changeVolume(.up)
        }
        if sentence.hasWord(in: Lexicon.quieter) || sentence.contains(any: Lexicon.quieterPhrases)
            || (aboutVolume && sentence.hasWord(startingWith: Lexicon.decrease)) {
            return .changeVolume(.down)
        }
        return nil
    }

    private static func specialLevel(in sentence: Sentence) -> Int? {
        if sentence.hasWord(startingWith: ["максим", "max"]) || sentence.contains(any: ["на полную", "full"]) { return 100 }
        if sentence.hasWord(startingWith: ["половин", "half"]) { return 50 }
        if sentence.hasWord(startingWith: ["миним", "min"]) { return 10 }
        return nil
    }

    // MARK: - Поиск в интернете

    /// «Найди в интернете рецепт борща», «загугли погоду», «search the web for cats».
    /// «Найди» без указания на интернет, но со словами про файлы — это поиск файлов (Phase 3b).
    private static func searchIntent(in sentence: Sentence) -> Intent? {
        let words = sentence.words
        var verbEnd: Int?
        // «google» — глагол только в начале («google cats»), а не в «open google chrome».
        if let index = words.firstIndex(where: { Lexicon.strongSearchVerbs.contains($0) }),
           words[index] != "google" || index == 0 {
            verbEnd = index + 1
        } else if let index = sentence.index(ofPhrase: ["look", "up"]) {
            verbEnd = index + 2
        } else if let index = words.firstIndex(where: { Lexicon.searchVerbs.contains($0) }) {
            // «Найди письмо от Пети», «найди файл диплом» — это почта и файлы, а не интернет.
            let mentionsWeb = sentence.contains(any: Lexicon.webMarkers)
            if !mentionsWeb, specificFeature(in: sentence) != nil { return nil }
            verbEnd = index + 1
        }
        guard let verbEnd else { return nil }
        var query = Array(words[verbEnd...])
        for marker in Lexicon.webMarkers {
            query = removing(TextNormalizer.words(marker), from: query)
        }
        query = trimmingFillers(query)
        guard !query.isEmpty else { return nil }
        return .webSearch(query.joined(separator: " "))
    }

    // MARK: - Приложения и сайты

    /// «Открой Safari», «закрой телеграм», «открой сайт github», «зайди на youtube.com».
    private static func appOrSiteIntent(in sentence: Sentence, rawText: String) -> Intent? {
        let words = sentence.words
        let quitIndex = words.firstIndex { Lexicon.quitVerbs.contains($0) }
        let openIndex = words.firstIndex { Lexicon.openVerbs.contains($0) }
        let siteIndex = words.firstIndex { Lexicon.siteVerbs.contains($0) }
        guard let verbIndex = quitIndex ?? openIndex ?? siteIndex else { return nil }

        var target = Array(words[(verbIndex + 1)...])
        // Составная команда: «открой почту и проверь непрочитанные» — пока не поддерживается.
        if let conjunction = target.firstIndex(where: { Lexicon.conjunctions.contains($0) }) {
            let rest = target[(conjunction + 1)...]
            if !rest.isEmpty { return .notYetSupported(specificFeature(in: sentence) ?? .multiStep) }
            target = Array(target[..<conjunction])
        }
        // «Закрой все/ненужные приложения» — действие над группой.
        if target.contains(where: { Lexicon.groupWords.contains($0) }) {
            return .notYetSupported(.multiStep)
        }
        // «Открой файл…», «открой загрузки» — это файлы (Phase 3b).
        if target.contains(where: { word in Lexicon.files.contains { word.hasPrefix($0) } }) {
            return .notYetSupported(.files)
        }

        let isQuit = quitIndex != nil
        if !isQuit {
            if let domain = SiteDirectory.domain(in: rawText) { return .openWebsite(domain) }
            if let site = target.firstIndex(where: { Lexicon.siteWords.contains($0) }) {
                let name = trimmingFillers(Array(target[(site + 1)...]))
                return name.isEmpty ? nil : .openWebsite(name.joined(separator: " "))
            }
        }

        let name = trimmingFillers(target)
        guard !name.isEmpty else { return nil }
        let joined = name.joined(separator: " ")
        if isQuit { return .quitApp(joined) }
        // «Зайди на ютуб» — сайт, «перейди в настройки» — приложение. «Открой ютуб» — приложение,
        // а если такого нет — сайт (это решает исполнитель).
        if openIndex == nil, let siteVerb = siteIndex {
            let preposition = siteVerb + 1 < words.count ? words[siteVerb + 1] : ""
            if preposition == "в" || preposition == "во" { return .openApp(joined) }
            if words[siteVerb] == "go", SiteDirectory.url(for: joined) == nil { return .openApp(joined) }
            return .openWebsite(joined)
        }
        return .openApp(joined)
    }

    /// Убирает служебные слова в начале и конце: «приложение», «пожалуйста», «на», «the»…
    private static func trimmingFillers(_ words: [String]) -> [String] {
        var result = words
        while let first = result.first, Lexicon.fillers.contains(first) { result.removeFirst() }
        while let last = result.last, Lexicon.fillers.contains(last) { result.removeLast() }
        return result
    }

    /// Убирает фразу (последовательность слов) из списка слов, где бы она ни стояла.
    private static func removing(_ phrase: [String], from words: [String]) -> [String] {
        guard !phrase.isEmpty, words.count >= phrase.count else { return words }
        var result: [String] = []
        var index = 0
        while index < words.count {
            if index + phrase.count <= words.count, Array(words[index..<(index + phrase.count)]) == phrase {
                index += phrase.count
            } else {
                result.append(words[index])
                index += 1
            }
        }
        return result
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

    /// Первое число в фразе («громкость 40» → 40).
    var firstNumber: Int? {
        words.lazy.compactMap { Int($0) }.first
    }

    /// Позиция, с которой начинается последовательность слов.
    func index(ofPhrase phrase: [String]) -> Int? {
        guard !phrase.isEmpty, words.count >= phrase.count else { return nil }
        return (0...(words.count - phrase.count)).first { Array(words[$0..<($0 + phrase.count)]) == phrase }
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

    static let mail = ["почт", "письм", "писем", "mail", "email", "inbox"]
    static let calendar = ["календар", "запланир", "встреч", "расписан", "calendar", "schedule", "meeting", "agenda"]
    static let reminders = ["напомн", "напоминан", "remind"]
    static let media = ["музык", "песн", "трек", "плейлист", "music", "song", "playlist"]
    static let system = [
        "громк", "ярк", "ярч", "вайфа", "wifi", "блютуз", "bluetooth", "volume", "brightness", "brighter", "dimmer",
        "буфер", "clipboard",
    ]
    static let files = ["файл", "папк", "документ", "pdf", "скачан", "загрузк", "file", "folder", "document", "download"]
    static let search = ["найди", "найти", "поищи", "ищи", "find", "search"]

    // Громкость.
    static let mute = [
        "выключи звук", "отключи звук", "убери звук", "без звука", "заглуши звук",
        "mute the sound", "mute sound", "mute audio", "mute the volume", "mute volume",
    ]
    static let unmute = ["включи звук", "верни звук", "unmute"]
    static let volume = ["громкост", "звук", "volume", "sound"]
    static let louder: Set<String> = ["громче", "погромче", "louder"]
    static let louderPhrases = ["volume up", "turn it up", "turn up the volume", "turn the volume up"]
    static let quieter: Set<String> = ["тише", "потише", "quieter"]
    static let quieterPhrases = ["volume down", "turn it down", "turn down the volume", "turn the volume down"]
    static let increase = ["прибав", "увелич", "подними", "increase", "raise"]
    static let decrease = ["убав", "уменьш", "понизь", "опусти", "decrease", "lower", "reduce"]

    // Интернет.
    static let strongSearchVerbs: Set<String> = ["загугли", "погугли", "гугли", "google"]
    static let searchVerbs: Set<String> = ["найди", "найти", "поищи", "поискать", "ищи", "search", "find"]
    static let webMarkers = [
        "в интернете", "в интернет", "в сети", "в гугле", "в google", "в яндексе", "в yandex", "в браузере",
        "on the web", "on the internet", "the web for", "the web", "on google",
    ]

    // Приложения и сайты.
    static let openVerbs: Set<String> = [
        "открой", "открыть", "откройте", "запусти", "запустить", "запустите", "переключись", "переключиться",
        "open", "launch", "start", "run", "switch",
    ]
    static let quitVerbs: Set<String> = ["закрой", "закрыть", "закройте", "заверши", "завершить", "выйди", "close", "quit", "exit"]
    static let siteVerbs: Set<String> = ["зайди", "перейди", "visit", "go"]
    static let siteWords: Set<String> = ["сайт", "website", "site"]
    static let conjunctions: Set<String> = ["и", "а", "потом", "затем", "and", "then"]
    static let groupWords: Set<String> = [
        "все", "всё", "ненужные", "лишние", "остальные", "другие", "all", "unused", "other", "others", "every",
    ]
    static let fillers: Set<String> = [
        "пожалуйста", "мне", "приложение", "приложения", "программу", "программа", "программы", "на", "в", "во",
        "к", "из", "про", "о", "об", "please", "the", "app", "application", "to", "me", "up", "for", "about",
    ]
}
