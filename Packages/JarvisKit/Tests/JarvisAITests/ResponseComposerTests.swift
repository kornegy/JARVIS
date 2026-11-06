import Foundation
import Testing
@testable import JarvisAI

@Suite("Ответы с характером")
struct ResponseComposerTests {
    private func composer(_ personality: Personality, _ language: ResponseLanguage = .russian, seed: UInt64 = 42) -> ResponseComposer {
        ResponseComposer(personality: personality, language: language, random: SeededRandomNumberGenerator(seed: seed))
    }

    @Test("Время подставляется в ответ")
    func timeValue() {
        var serious = composer(Personality(humor: 0, verbosity: 0.5, formality: 0.2))
        #expect(serious.reply(to: .currentTime, value: "14:35") == "Сейчас 14:35.")
    }

    @Test("Без юмора шуток нет никогда")
    func noHumorNoQuips() {
        for seed in 0..<50 {
            var serious = composer(Personality(humor: 0, verbosity: 0.5, formality: 0.2), seed: UInt64(seed))
            #expect(serious.reply(to: .currentTime, value: "09:00") == "Сейчас 09:00.")
        }
    }

    @Test("С максимальным юмором шутки иногда появляются")
    func humorAddsQuips() {
        var funny = composer(Personality(humor: 1, verbosity: 0.5, formality: 0.2))
        let replies = (0..<40).map { _ in funny.reply(to: .currentTime, value: "09:00") }
        #expect(replies.contains { $0 != "Сейчас 09:00." })
        #expect(replies.allSatisfy { $0.hasPrefix("Сейчас 09:00.") })
    }

    @Test("Краткий режим — самый короткий вариант и без шуток")
    func briefMode() {
        var brief = composer(Personality(humor: 1, verbosity: 0, formality: 0))
        for _ in 0..<20 {
            #expect(brief.reply(to: .currentTime, value: "09:00") == "09:00.")
            #expect(brief.reply(to: .disableAssistant) == "Выключаюсь.")
        }
    }

    @Test("Официальный стиль обращается на «вы»")
    func formalStyle() {
        var formal = composer(Personality(humor: 0, verbosity: 0.5, formality: 1))
        #expect(formal.reply(to: .greeting) == "Здравствуйте! Чем могу помочь?")
        #expect(formal.reply(to: .unknown).contains("Скажите"))
    }

    @Test("Неподдержанная возможность называется по имени")
    func notYetSupported() {
        var russian = composer(Personality(humor: 0, verbosity: 0.5, formality: 0))
        #expect(russian.reply(to: .notYetSupported(.mail)) == "Работать с почтой я научусь в следующей версии.")
        var english = composer(Personality(humor: 0, verbosity: 0.5, formality: 0), .english)
        #expect(english.reply(to: .notYetSupported(.files)) == "I'll learn to work with files in the next version.")
    }

    @Test("У каждого намерения есть ответ на обоих языках, кроме пустого")
    func everyIntentHasReply() {
        let intents: [Intent] = [
            .greeting, .thanks, .capabilities, .cancel, .currentTime, .currentDate, .disableAssistant,
            .pauseMicrophone, .setPrivacyMode(true), .setPrivacyMode(false), .notYetSupported(.apps), .unknown,
        ]
        for language in [ResponseLanguage.russian, .english] {
            var replies = composer(Personality(), language)
            for intent in intents {
                let reply = replies.reply(to: intent, value: "X")
                #expect(!reply.isEmpty)
                #expect(!reply.contains("{"))
            }
            #expect(replies.reply(to: .empty).isEmpty)
        }
    }

    @Test("Язык ответа следует за локалью")
    func languageFromLocale() {
        #expect(ResponseLanguage(locale: Locale(identifier: "en_US")) == .english)
        #expect(ResponseLanguage(locale: Locale(identifier: "ru_RU")) == .russian)
        #expect(ResponseLanguage(locale: Locale(identifier: "cs_CZ")) == .russian)
    }

    @Test("Генератор с одинаковым зерном воспроизводим")
    func seededGenerator() {
        var first = SeededRandomNumberGenerator(seed: 7)
        var second = SeededRandomNumberGenerator(seed: 7)
        #expect((0..<5).map { _ in first.next() } == (0..<5).map { _ in second.next() })
    }
}
