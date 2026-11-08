/// Приложение-кандидат для поиска по имени.
public struct AppNameCandidate: Sendable, Equatable {
    /// Любой уникальный идентификатор (путь к приложению или bundle id).
    public let id: String
    /// Все известные имена: локализованное («Заметки»), английское («Notes»), имя файла.
    public let names: [String]

    public init(id: String, names: [String]) {
        self.id = id
        self.names = names
    }
}

/// Находит приложение по тому, как его назвал пользователь.
///
/// Распознавание речи пишет названия по-разному: «сафари», «Safari», «телеграма»,
/// «хром». Поэтому сравнение идёт по нескольким признакам: точное совпадение, одинаковая
/// латинская «форма» слова («сафари» = «safari»), все слова запроса есть в имени
/// («chrome» ⊂ «Google Chrome»), нечёткое совпадение слов (падежи: «почту» ≈ «почта»),
/// плюс словарь разговорных названий («хром» → Google Chrome).
///
/// Чистая логика без macOS — полностью покрыта тестами.
public enum AppNameMatcher {
    /// Ниже этой оценки считаем, что подходящего приложения нет.
    static let minimumScore = 65

    public static func bestMatch(for spokenName: String, in candidates: [AppNameCandidate]) -> AppNameCandidate? {
        let queries = queryForms(spokenName)
        guard !queries.isEmpty else { return nil }

        var best: (candidate: AppNameCandidate, score: Int, nameLength: Int)?
        for candidate in candidates {
            for name in candidate.names {
                let normalizedName = TextNormalizer.normalize(name)
                let score = queries.map { score(query: $0, name: normalizedName) }.max() ?? 0
                guard score >= minimumScore else { continue }
                let length = normalizedName.count
                if let current = best {
                    // Выше оценка — лучше; при равной — короче имя (точнее совпадение).
                    if score > current.score || (score == current.score && length < current.nameLength) {
                        best = (candidate, score, length)
                    }
                } else {
                    best = (candidate, score, length)
                }
            }
        }
        return best?.candidate
    }

    /// Запрос и его варианты из словаря разговорных названий.
    static func queryForms(_ spokenName: String) -> [String] {
        let normalized = TextNormalizer.normalize(spokenName)
        guard !normalized.isEmpty else { return [] }
        var forms = [normalized]
        for alias in aliases where alias.spoken.contains(where: { phraseMatches($0, normalized) }) {
            if !forms.contains(alias.name) { forms.append(alias.name) }
        }
        return forms
    }

    /// Оценка совпадения нормализованных запроса и имени (0…100).
    static func score(query: String, name: String) -> Int {
        guard !query.isEmpty, !name.isEmpty else { return 0 }
        if name == query { return 100 }
        if FuzzyWord.skeleton(name) == FuzzyWord.skeleton(query) { return 95 }

        let nameWords = name.split(separator: " ").map(String.init)
        let queryWords = query.split(separator: " ").map(String.init)
        if queryWords.allSatisfy({ nameWords.contains($0) }) { return 80 }
        if queryWords.allSatisfy({ word in nameWords.contains { FuzzyWord.matches(word, $0) } }) { return 70 }
        let joinedQuery = queryWords.joined()
        let joinedName = nameWords.joined()
        if joinedQuery.count >= 4, FuzzyWord.matches(joinedQuery, joinedName) { return 65 }
        return 0
    }

    /// Фраза из словаря совпадает с запросом: целиком или (для одного слова) нечётко.
    static func phraseMatches(_ phrase: String, _ query: String) -> Bool {
        if phrase == query { return true }
        let phraseWords = phrase.split(separator: " ")
        let queryWords = query.split(separator: " ")
        guard phraseWords.count == queryWords.count else { return false }
        return zip(phraseWords, queryWords).allSatisfy { FuzzyWord.matches(String($0), String($1)) }
    }

    /// Разговорные названия → английское имя приложения (нормализованное).
    /// Встроенные приложения macOS на русской системе и так называются по-русски
    /// («Заметки», «Почта») — они находятся по локализованному имени.
    static let aliases: [(spoken: [String], name: String)] = [
        (["хром", "гугл хром"], "google chrome"),
        (["яндекс браузер", "яндекс"], "yandex"),
        (["ворд"], "microsoft word"),
        (["эксель", "ексель"], "microsoft excel"),
        (["пауэрпоинт", "поверпоинт"], "microsoft powerpoint"),
        (["аутлук"], "microsoft outlook"),
        (["тимс"], "microsoft teams"),
        (["телеграм", "телеграмм", "телега"], "telegram"),
        (["вотсап", "ватсап", "вацап"], "whatsapp"),
        (["вайбер"], "viber"),
        (["скайп"], "skype"),
        (["зум"], "zoom us"),
        (["слак", "слэк"], "slack"),
        (["дискорд"], "discord"),
        (["спотифай"], "spotify"),
        (["ноушн", "ноушен"], "notion"),
        (["фигма"], "figma"),
        (["обсидиан"], "obsidian"),
        (["вс код", "вскод", "визуал студио код", "визуал студио"], "visual studio code"),
        (["икскод", "хкод"], "xcode"),
        (["райдер"], "rider"),
        (["пайчарм"], "pycharm"),
        (["интеллидж"], "intellij idea"),
        (["файндер"], "finder"),
        (["настройки", "системные настройки"], "system settings"),
        (["терминал"], "terminal"),
        (["айтерм"], "iterm"),
        (["фотошоп"], "adobe photoshop"),
        (["просмотр", "превью"], "preview"),
        (["текстэдит", "текст эдит"], "textedit"),
        (["фейстайм"], "facetime"),
        (["апп стор", "эп стор", "апстор", "магазин приложений"], "app store"),
        (["музыка", "музыку"], "music"),
        (["подкасты"], "podcasts"),
        (["заметки"], "notes"),
        (["напоминания"], "reminders"),
        (["календарь"], "calendar"),
        (["почта", "почту"], "mail"),
        (["сообщения"], "messages"),
        (["карты"], "maps"),
        (["фото", "фотографии"], "photos"),
        (["контакты"], "contacts"),
        (["калькулятор"], "calculator"),
        (["часы"], "clock"),
        (["погода"], "weather"),
    ]
}
