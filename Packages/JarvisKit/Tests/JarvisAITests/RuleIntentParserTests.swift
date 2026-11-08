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
        ("Открой Rider и продолжи работу над моим проектом", Feature.apps),
        ("Найди файл с названием диплом", Feature.files),
        ("Создай папку для нового проекта", Feature.files),
        ("Закрой ненужные приложения", Feature.apps),
        ("Напомни мне завтра продолжить изучение C++", Feature.reminders),
        ("Что у меня сегодня запланировано?", Feature.calendar),
        ("Сделай краткое содержание непрочитанных писем", Feature.mail),
        ("Найди все файлы, которые я изменял за последние три дня", Feature.files),
        ("Запусти музыку и открой браузер", Feature.media),
        ("сделай громче", Feature.system),
        ("открой сайт github", Feature.web),
    ])
    func futureFeatures(text: String, feature: Feature) {
        #expect(parser.parse(text) == .notYetSupported(feature))
    }

    @Test("Непонятное и пустое")
    func unknownAndEmpty() {
        #expect(parser.parse("расскажи анекдот про квантовую физику") == .unknown)
        #expect(parser.parse("   ") == .empty)
        #expect(parser.parse("?!") == .empty)
    }
}
