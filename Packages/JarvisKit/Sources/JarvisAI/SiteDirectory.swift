import Foundation

/// Сайты, которые можно открыть голосом: адрес («github.com») или известное название («ютуб»).
///
/// Только `https`. Сайт открывается в браузере пользователя — JARVIS сам в сеть не ходит.
public enum SiteDirectory {
    /// Адрес сайта по тому, как его назвал пользователь; `nil` — непонятно, что открывать.
    public static func url(for spokenName: String) -> URL? {
        if let address = Self.domain(in: spokenName) {
            return URL(string: "https://\(address)")
        }
        let normalized = TextNormalizer.normalize(spokenName)
        guard !normalized.isEmpty else { return nil }
        for site in known where site.names.contains(where: { AppNameMatcher.phraseMatches($0, normalized) }) {
            return URL(string: "https://\(site.host)")
        }
        return nil
    }

    /// Первый адрес вида «example.com» в тексте (только латиница, буквенный домен верхнего уровня).
    public static func domain(in text: String) -> String? {
        let lowered = text.lowercased()
        // Метки домена из латиницы, цифр и дефисов; домен верхнего уровня — от двух букв.
        let pattern = /(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}(?![a-z0-9])/
        guard let match = lowered.firstMatch(of: pattern) else { return nil }
        return String(lowered[match.range])
    }

    static let known: [(names: [String], host: String)] = [
        (["ютуб", "ютюб", "youtube", "you tube"], "www.youtube.com"),
        (["гугл", "google"], "www.google.com"),
        (["яндекс", "yandex"], "ya.ru"),
        (["вк", "вконтакте", "в контакте", "vk"], "vk.com"),
        (["гитхаб", "гит хаб", "github"], "github.com"),
        (["википедия", "вики", "wikipedia"], "www.wikipedia.org"),
        (["джимейл", "гмейл", "gmail"], "mail.google.com"),
        (["авито", "avito"], "www.avito.ru"),
        (["озон", "ozon"], "www.ozon.ru"),
        (["вайлдберриз", "wildberries"], "www.wildberries.ru"),
        (["кинопоиск"], "www.kinopoisk.ru"),
        (["хабр", "habr"], "habr.com"),
        (["чат гпт", "чатгпт", "chatgpt", "chat gpt"], "chatgpt.com"),
        (["клод", "claude"], "claude.ai"),
        (["стак оверфлоу", "stack overflow", "stackoverflow"], "stackoverflow.com"),
        (["переводчик", "гугл переводчик", "google translate"], "translate.google.com"),
    ]
}
