import Foundation
import Testing
@testable import JarvisCore

@Suite("Приватные типы не раскрывают содержимое")
struct PrivacyTypesTests {
    private let secret = "найди мой паспорт в документах"

    @Test("Utterance не раскрывает текст при печати, интерполяции и dump")
    func utteranceIsRedacted() {
        let utterance = Utterance(text: secret, locale: Locale(identifier: "ru_RU"))

        #expect(!String(describing: utterance).contains(secret))
        #expect(!String(reflecting: utterance).contains(secret))
        #expect(!"\(utterance)".contains(secret))

        var dumped = ""
        dump(utterance, to: &dumped)
        #expect(!dumped.contains(secret))
        #expect(Mirror(reflecting: utterance).children.isEmpty)

        // Явный доступ к тексту по-прежнему работает — он нужен для интерпретации.
        #expect(utterance.text == secret)
    }

    @Test("Utterance нельзя сериализовать")
    func utteranceIsNotCodable() {
        let utterance = Utterance(text: secret, locale: Locale(identifier: "ru_RU"))
        #expect(!((utterance as Any) is any Encodable))
        #expect(!((utterance as Any) is any Decodable))
    }

    @Test("Пустая фраза распознаётся")
    func blankUtterance() {
        #expect(Utterance(text: "  \n", locale: Locale(identifier: "ru_RU")).isBlank)
        #expect(!Utterance(text: "привет", locale: Locale(identifier: "ru_RU")).isBlank)
    }

    @Test("Sensitive скрывает значение")
    func sensitiveIsRedacted() {
        let apiKey = Sensitive("sk-test-1234567890")
        #expect(String(describing: apiKey) == "<redacted>")
        #expect("\(apiKey)" == "<redacted>")
        var dumped = ""
        dump(apiKey, to: &dumped)
        #expect(!dumped.contains("sk-test"))
        #expect(apiKey.revealed == "sk-test-1234567890")
    }
}
