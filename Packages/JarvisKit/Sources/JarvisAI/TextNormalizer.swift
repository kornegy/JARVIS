/// Приводит распознанный текст к единому виду для сравнения:
/// нижний регистр, «ё» → «е», знаки препинания → пробелы, без повторных пробелов.
///
/// «Привет, Джарвис! Который час?» → «привет джарвис который час».
public enum TextNormalizer {
    public static func normalize(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingSpace && !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(character == "ё" ? "е" : character)
            } else {
                pendingSpace = true
            }
        }
        return result
    }

    /// Слова нормализованного текста.
    public static func words(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }
}

/// Нечёткое сравнение слов: распознавание речи может написать «Джарвис», «Jarvis»,
/// «Джервис» или «Жарвис» — для фразы-активатора это одно и то же.
enum FuzzyWord {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = Array(skeleton(lhs))
        let right = Array(skeleton(rhs))
        if left == right { return true }
        let length = max(left.count, right.count)
        let allowedEdits = length >= 8 ? 2 : (length >= 5 ? 1 : 0)
        guard allowedEdits > 0, abs(left.count - right.count) <= allowedEdits else { return false }
        return editDistance(left, right) <= allowedEdits
    }

    /// Упрощённая латинская «форма» слова: кириллица и латиница сводятся к общему виду.
    static func skeleton(_ word: String) -> String {
        var output = ""
        let characters = Array(word)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "д", index + 1 < characters.count, characters[index + 1] == "ж" {
                output.append("j")
                index += 2
                continue
            }
            output.append(transliteration[character] ?? String(character))
            index += 1
        }
        return output
    }

    private static let transliteration: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ж": "j", "з": "z",
        "и": "i", "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p",
        "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "ch",
        "ш": "sh", "щ": "sh", "ъ": "", "ы": "i", "ь": "", "э": "e", "ю": "u", "я": "a",
        "y": "i",
    ]

    /// Расстояние Левенштейна: сколько вставок, удалений и замен превращают одно слово в другое.
    static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
