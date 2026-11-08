import Testing
@testable import JarvisAI

@Suite("Разбор команд по правилам")
struct RuleIntentParserTests {
    private let parser = RuleIntentParser()

    @Test("Время", arguments: ["Который час?", "сколько сейчас времени", "время", "What time is it?"])
    func time(text: String) {
        #expect(parser.parse(text) == .currentTime)
    }

    @Test("Дата", arguments: ["Какое сегодня число?", "какой сегодня день", "какая дата", "What's the date?"])
    func date(text: String) {
        #expect(parser.parse(text) == .currentDate)
    }

    @Test("Что ты умеешь", arguments: ["Что ты умеешь?", "что ты можешь сделать для меня", "помощь", "What can you do?"])
    func capabilities(text: String) {
        #expect(parser.parse(text) == .capabilities)
    }

    @Test("Приватный режим")
    func privacyMode() {
        #expect(parser.parse("Включи приватный режим") == .setPrivacyMode(true))
        #expect(parser.parse("выключи приватный режим") == .setPrivacyMode(false))
        #expect(parser.parse("отключи режим конфиденциальности") == .setPrivacyMode(false))
        #expect(parser.parse("privacy mode on") == .setPrivacyMode(true))
        #expect(parser.parse("turn off privacy mode") == .setPrivacyMode(false))
    }

    @Test("Управление ассистентом")
    func assistantControl() {
        #expect(parser.parse("Выключись") == .disableAssistant)
        #expect(parser.parse("go to sleep") == .disableAssistant)
        #expect(parser.parse("не слушай меня") == .pauseMicrophone)
        #expect(parser.parse("выключи микрофон") == .pauseMicrophone)
        #expect(parser.parse("пауза") == .pauseMicrophone)
    }

    @Test("«Turn off» без уточнения выключает ассистента, а «turn off the lights» — нет")
    func turnOffIsExactOnly() {
        #expect(parser.parse("turn off") == .disableAssistant)
        #expect(parser.parse("turn off the lights") != .disableAssistant)
    }

    @Test("Отмена, благодарность, приветствие")
    func smallTalk() {
        #expect(parser.parse("отмена") == .cancel)
        #expect(parser.parse("Забудь") == .cancel)
        #expect(parser.parse("Спасибо!") == .thanks)
        #expect(parser.parse("Привет") == .greeting)
        #expect(parser.parse("доброе утро") == .greeting)
        #expect(parser.parse("hello") == .greeting)
    }

    @Test("Примеры из ТЗ узнаются, даже если пока не поддержаны", arguments: [
        ("открой почту и проверь непрочитанные сообщения", Feature.mail),
        ("Найди последний PDF, который я скачал", Feature.files),
        ("Открой Rider и продолжи работу над моим проектом", Feature.multiStep),
        ("Найди файл с названием диплом", Feature.files),
        ("Создай папку для нового проекта", Feature.files),
        ("Закрой ненужные приложения", Feature.multiStep),
        ("Напомни мне завтра продолжить изучение C++", Feature.reminders),
        ("Что у меня сегодня запланировано?", Feature.calendar),
        ("Сделай краткое содержание непрочитанных писем", Feature.mail),
        ("Найди все файлы, которые я изменял за последние три дня", Feature.files),
        ("Запусти музыку и открой браузер", Feature.media),
        ("открой файл отчёт", Feature.files),
        ("найди письмо от Пети", Feature.mail),
        ("сделай ярче", Feature.system),
    ])
    func futureFeatures(text: String, feature: Feature) {
        #expect(parser.parse(text) == .notYetSupported(feature))
    }

    @Test("Приложения: открыть, переключиться, закрыть")
    func apps() {
        #expect(parser.parse("Открой Safari") == .openApp("safari"))
        #expect(parser.parse("открой, пожалуйста, приложение заметки") == .openApp("заметки"))
        #expect(parser.parse("запусти телеграм") == .openApp("телеграм"))
        #expect(parser.parse("переключись на хром") == .openApp("хром"))
        #expect(parser.parse("перейди в настройки") == .openApp("настройки"))
        #expect(parser.parse("open Visual Studio Code") == .openApp("visual studio code"))
        #expect(parser.parse("switch to Finder") == .openApp("finder"))
        #expect(parser.parse("Закрой Safari") == .quitApp("safari"))
        #expect(parser.parse("выйди из телеграма") == .quitApp("телеграма"))
        #expect(parser.parse("quit Spotify please") == .quitApp("spotify"))
        #expect(parser.parse("открой") == .unknown)
    }

    @Test("Сайты и поиск в интернете")
    func web() {
        #expect(parser.parse("открой сайт github") == .openWebsite("github"))
        #expect(parser.parse("зайди на ютуб") == .openWebsite("ютуб"))
        #expect(parser.parse("Открой github.com") == .openWebsite("github.com"))
        #expect(parser.parse("go to youtube") == .openWebsite("youtube"))
        #expect(parser.parse("visit apple.com") == .openWebsite("apple.com"))
        #expect(parser.parse("найди в интернете рецепт борща") == .webSearch("рецепт борща"))
        #expect(parser.parse("поищи рецепт борща в гугле") == .webSearch("рецепт борща"))
        #expect(parser.parse("загугли погоду в Москве") == .webSearch("погоду в москве"))
        #expect(parser.parse("найди рецепт блинов") == .webSearch("рецепт блинов"))
        #expect(parser.parse("search the web for swift concurrency") == .webSearch("swift concurrency"))
        #expect(parser.parse("look up the weather") == .webSearch("weather"))
        #expect(parser.parse("google swift testing") == .webSearch("swift testing"))
        #expect(parser.parse("open google chrome") == .openApp("google chrome"))
    }

    @Test("Громкость")
    func volume() {
        #expect(parser.parse("громкость 40") == .setVolume(40))
        #expect(parser.parse("сделай громкость на 30%") == .setVolume(30))
        #expect(parser.parse("громкость на максимум") == .setVolume(100))
        #expect(parser.parse("set volume to 150") == .setVolume(100))
        #expect(parser.parse("сделай громче") == .changeVolume(.up))
        #expect(parser.parse("прибавь звук") == .changeVolume(.up))
        #expect(parser.parse("потише") == .changeVolume(.down))
        #expect(parser.parse("убавь громкость") == .changeVolume(.down))
        #expect(parser.parse("volume down") == .changeVolume(.down))
        #expect(parser.parse("выключи звук") == .setMuted(true))
        #expect(parser.parse("включи звук") == .setMuted(false))
        #expect(parser.parse("unmute") == .setMuted(false))
        // Микрофон — не звук.
        #expect(parser.parse("выключи микрофон") == .pauseMicrophone)
        #expect(parser.parse("mute") == .pauseMicrophone)
    }

    @Test("Непонятное и пустое")
    func unknownAndEmpty() {
        #expect(parser.parse("расскажи анекдот про квантовую физику") == .unknown)
        #expect(parser.parse("   ") == .empty)
        #expect(parser.parse("?!") == .empty)
    }
}
