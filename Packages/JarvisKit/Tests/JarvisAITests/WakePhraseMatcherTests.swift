import Testing
@testable import JarvisAI

@Suite("Нормализация текста")
struct TextNormalizerTests {
    @Test("Регистр, «ё», пунктуация и пробелы", arguments: [
        ("Привет, Джарвис! Который час?", "привет джарвис который час"),
        ("  Ёлки-палки  ", "елки палки"),
        ("What's the date?", "what s the date"),
        ("Громкость 30%", "громкость 30"),
        ("…", ""),
    ])
    func normalize(input: String, expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }
}

@Suite("Нечёткое сравнение слов")
struct FuzzyWordTests {
    @Test("Варианты имени совпадают", arguments: ["джарвис", "Jarvis", "джервис", "жарвис", "jarvis"])
    func nameVariants(word: String) {
        #expect(FuzzyWord.matches("джарвис", TextNormalizer.normalize(word)))
    }

    @Test("Похожие, но другие слова не совпадают", arguments: ["дарвин", "чарли", "джаз", "привет", "и"])
    func differentWords(word: String) {
        #expect(!FuzzyWord.matches("джарвис", word))
    }

    @Test("Короткие слова сравниваются строго")
    func shortWordsAreExact() {
        #expect(!FuzzyWord.matches("да", "до"))
        #expect(FuzzyWord.matches("да", "да"))
    }

    @Test("Расстояние Левенштейна")
    func editDistance() {
        #expect(FuzzyWord.editDistance(Array("kitten"), Array("sitting")) == 3)
        #expect(FuzzyWord.editDistance(Array(""), Array("abc")) == 3)
        #expect(FuzzyWord.editDistance(Array("jarvis"), Array("jarvis")) == 0)
    }
}

@Suite("Фраза-активатор")
struct WakePhraseMatcherTests {
    private let matcher = WakePhraseMatcher(phrases: ["Привет, Джарвис", "hey jarvis"])

    @Test("Фраза находится и возвращается остаток команды")
    func detectsWakePhrase() {
        #expect(matcher.remainder(afterWakePhraseIn: "Привет, Джарвис, открой почту") == "открой почту")
        #expect(matcher.remainder(afterWakePhraseIn: "ну ладно привет джарвис который час") == "который час")
        #expect(matcher.remainder(afterWakePhraseIn: "Hey Jarvis what time is it") == "what time is it")
        #expect(matcher.remainder(afterWakePhraseIn: "Привет, Джарвис") == "")
    }

    @Test("Нечёткие варианты распознавания тоже срабатывают")
    func fuzzyWakePhrase() {
        #expect(matcher.remainder(afterWakePhraseIn: "привет джервис который час") == "который час")
        #expect(matcher.remainder(afterWakePhraseIn: "превет jarvis") == "")
    }

    @Test("Обычная речь не активирует ассистента", arguments: [
        "привет как дела",
        "джарвис это персонаж из фильма",
        "передай привет маше",
        "мы говорили про дарвина",
        "",
    ])
    func noFalsePositives(text: String) {
        #expect(matcher.remainder(afterWakePhraseIn: text) == nil)
    }

    @Test("Команда после обращения: полная фраза или только имя")
    func commandAfterAddress() {
        #expect(matcher.command(afterAddressIn: "Привет, Джарвис, который час") == "который час")
        #expect(matcher.command(afterAddressIn: "джарвис который час") == "который час")
        #expect(matcher.command(afterAddressIn: "просто разговор") == "")
    }

    @Test("Обращение убирается в начале и в конце команды")
    func stripsAddress() {
        #expect(matcher.strippingAddress(from: "Джарвис, который час") == "который час")
        #expect(matcher.strippingAddress(from: "Который час, Джарвис?") == "который час")
        #expect(matcher.strippingAddress(from: "Привет, Джарвис, что ты умеешь") == "что ты умеешь")
        #expect(matcher.strippingAddress(from: "который час") == "который час")
        #expect(matcher.strippingAddress(from: "Джарвис") == "")
    }

    @Test("Пустые и повторяющиеся фразы игнорируются")
    func ignoresEmptyPhrases() {
        let custom = WakePhraseMatcher(phrases: ["", "  ", "Пятница", "пятница"])
        #expect(custom.phrases == [["пятница"]])
        #expect(custom.remainder(afterWakePhraseIn: "Пятница, который час") == "который час")
    }
}
