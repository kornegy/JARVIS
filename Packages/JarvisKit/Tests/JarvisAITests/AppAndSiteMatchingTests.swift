import Foundation
import Testing
@testable import JarvisAI

@Suite("Поиск приложения по имени")
struct AppNameMatcherTests {
    private let installed = [
        AppNameCandidate(id: "safari", names: ["Safari"]),
        AppNameCandidate(id: "chrome", names: ["Google Chrome"]),
        AppNameCandidate(id: "remote", names: ["Chrome Remote Desktop"]),
        AppNameCandidate(id: "notes", names: ["Заметки", "Notes"]),
        AppNameCandidate(id: "mail", names: ["Почта", "Mail"]),
        AppNameCandidate(id: "telegram", names: ["Telegram"]),
        AppNameCandidate(id: "settings", names: ["Системные настройки", "System Settings"]),
        AppNameCandidate(id: "vscode", names: ["Visual Studio Code"]),
        AppNameCandidate(id: "calculator", names: ["Calculator"]),
        AppNameCandidate(id: "spotify", names: ["Spotify"]),
    ]

    private func match(_ spoken: String) -> String? {
        AppNameMatcher.bestMatch(for: spoken, in: installed)?.id
    }

    @Test("Точное имя, транслитерация и падежи", arguments: [
        ("safari", "safari"), ("сафари", "safari"), ("Заметки", "notes"), ("notes", "notes"),
        ("почту", "mail"), ("телеграма", "telegram"), ("телеграм", "telegram"), ("спотифай", "spotify"),
    ])
    func directMatches(spoken: String, expected: String) {
        #expect(match(spoken) == expected)
    }

    @Test("Разговорные названия", arguments: [
        ("хром", "chrome"), ("гугл хром", "chrome"), ("chrome", "chrome"), ("настройки", "settings"),
        ("вс код", "vscode"), ("калькулятор", "calculator"),
    ])
    func aliases(spoken: String, expected: String) {
        #expect(match(spoken) == expected)
    }

    @Test("Непохожее не находится — лучше «не нашёл», чем закрыть не то")
    func noFalseMatches() {
        #expect(match("фотошоп") == nil)
        #expect(match("ненужные") == nil)
        #expect(match("") == nil)
        #expect(match("x") == nil)
    }
}

@Suite("Услышанный текст для экрана")
struct HeardTextTests {
    private let matcher = WakePhraseMatcher(phrases: ["привет джарвис", "hey jarvis"])

    @Test("Показываем с фразы-активатора, как распознано; чужую речь до неё — нет")
    func heardText() {
        #expect(matcher.heardText(fromWakePhraseIn: "Привет, Джарвис, который час?") == "Привет, Джарвис, который час?")
        #expect(matcher.heardText(fromWakePhraseIn: "ну ладно привет Джарвис, который час") == "привет Джарвис, который час")
        #expect(matcher.heardText(fromWakePhraseIn: "что-то там — hey Jarvis open Safari") == "hey Jarvis open Safari")
        #expect(matcher.heardText(fromWakePhraseIn: "без обращения") == "без обращения")
    }
}

@Suite("Сайты")
struct SiteDirectoryTests {
    @Test("Адрес из текста")
    func domains() {
        #expect(SiteDirectory.domain(in: "открой github.com пожалуйста") == "github.com")
        #expect(SiteDirectory.domain(in: "docs.swift.org") == "docs.swift.org")
        #expect(SiteDirectory.domain(in: "версия 1.5") == nil)
        #expect(SiteDirectory.domain(in: "сафари") == nil)
    }

    @Test("Известные сайты по названию и только https")
    func knownSites() {
        #expect(SiteDirectory.url(for: "ютуб")?.absoluteString == "https://www.youtube.com")
        #expect(SiteDirectory.url(for: "википедию")?.absoluteString == "https://www.wikipedia.org")
        #expect(SiteDirectory.url(for: "github.com")?.absoluteString == "https://github.com")
        #expect(SiteDirectory.url(for: "неизвестно что") == nil)
    }
}

@Suite("Ответ «да» или «нет»")
struct ConfirmationAnswerTests {
    @Test("Да", arguments: ["да", "Да, закрывай", "конечно", "давай", "ок", "yes", "sure", "go ahead"])
    func yes(text: String) {
        #expect(ConfirmationAnswer.parse(text) == true)
    }

    @Test("Нет — в том числе если есть хоть одно «нет»", arguments: ["нет", "не надо", "да нет", "отмена", "стоп", "no", "don't"])
    func no(text: String) {
        #expect(ConfirmationAnswer.parse(text) == false)
    }

    @Test("Непонятное — не согласие")
    func unclear() {
        #expect(ConfirmationAnswer.parse("который час") == nil)
        #expect(ConfirmationAnswer.parse("") == nil)
        #expect(ConfirmationAnswer.parse("точно закрыть safari") == nil)
    }
}
