/// Поиск фразы-активатора («Привет, Джарвис») в распознанном тексте.
///
/// Работает по словам и нечётко (см. `FuzzyWord`), поэтому «привет джервис» или
/// «привет jarvis» тоже сработают. Короткие слова сравниваются строго, чтобы не
/// было ложных срабатываний.
public struct WakePhraseMatcher: Sendable, Equatable {
    /// Фразы-активаторы в виде нормализованных слов (длинные — первыми).
    public let phrases: [[String]]
    /// Варианты обращения для очистки команды: фразы + их последнее слово (имя).
    let addressForms: [[String]]

    public init(phrases: [String]) {
        let normalized = phrases
            .map(TextNormalizer.words)
            .filter { !$0.isEmpty }
        var unique: [[String]] = []
        for phrase in normalized where !unique.contains(phrase) {
            unique.append(phrase)
        }
        self.phrases = unique.sorted { $0.count > $1.count }

        var forms = unique
        for phrase in unique where phrase.count > 1 {
            if let name = phrase.last, !forms.contains([name]) {
                forms.append([name])
            }
        }
        self.addressForms = forms.sorted { $0.count > $1.count }
    }

    /// Есть ли в тексте фраза-активатор. Возвращает слова после неё (может быть пусто).
    public func remainder(afterWakePhraseIn text: String) -> String? {
        let words = TextNormalizer.words(text)
        guard let match = firstMatch(of: phrases, in: words) else { return nil }
        return words[match.end...].joined(separator: " ")
    }

    /// Услышанный текст начиная с фразы-активатора — для показа на экране. Регистр и знаки —
    /// как распознано; всё сказанное до фразы (чужая речь) отбрасывается.
    public func heardText(fromWakePhraseIn text: String) -> String {
        let words = TextNormalizer.words(text)
        guard let match = firstMatch(of: phrases, in: words), match.start > 0 else { return text }
        var wordsToDrop = match.start
        var tokens = text.split(whereSeparator: { $0.isWhitespace })
        while wordsToDrop > 0, let first = tokens.first {
            wordsToDrop -= TextNormalizer.words(String(first)).count
            tokens.removeFirst()
        }
        // Знаки препинания, оставшиеся перед фразой («— hey Jarvis»), тоже убираем.
        while let first = tokens.first, TextNormalizer.words(String(first)).isEmpty {
            tokens.removeFirst()
        }
        return tokens.joined(separator: " ")
    }

    /// Текст команды после фразы-активатора или имени (режим wake word).
    /// Если обращения нет — пустая строка.
    public func command(afterAddressIn text: String) -> String {
        let words = TextNormalizer.words(text)
        guard let match = firstMatch(of: addressForms, in: words) else { return "" }
        return words[match.end...].joined(separator: " ")
    }

    /// Убирает обращение в начале или в конце команды (Push-to-Talk, текстовый ввод):
    /// «Джарвис, который час» и «который час, Джарвис» → «который час».
    public func strippingAddress(from text: String) -> String {
        var words = TextNormalizer.words(text)
        if let match = firstMatch(of: addressForms, in: words), match.start == 0 {
            words.removeFirst(match.end)
        }
        for form in addressForms where words.count > form.count {
            let tail = Array(words.suffix(form.count))
            if zip(form, tail).allSatisfy({ FuzzyWord.matches($0.0, $0.1) }) {
                words.removeLast(form.count)
                break
            }
        }
        return words.joined(separator: " ")
    }

    private func firstMatch(of candidates: [[String]], in words: [String]) -> (start: Int, end: Int)? {
        for start in words.indices {
            for phrase in candidates where start + phrase.count <= words.count {
                let window = words[start..<(start + phrase.count)]
                if zip(phrase, window).allSatisfy({ FuzzyWord.matches($0.0, $0.1) }) {
                    return (start, start + phrase.count)
                }
            }
        }
        return nil
    }
}
