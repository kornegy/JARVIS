/// Ответ на вопрос «Точно закрыть Safari?»: да, нет или непонятно.
///
/// Безопасность важнее удобства: если в ответе есть хоть одно «нет» («да нет», «не надо»),
/// это «нет». Непонятный ответ — тоже не согласие (решает вызывающий код: ничего не делать).
public enum ConfirmationAnswer {
    /// `true` — да, `false` — нет, `nil` — ответ не распознан.
    public static func parse(_ text: String) -> Bool? {
        let words = TextNormalizer.words(text)
        guard !words.isEmpty else { return nil }
        let padded = " " + words.joined(separator: " ") + " "
        if negative.contains(where: { padded.contains(" \($0) ") }) { return false }
        if positive.contains(where: { padded.contains(" \($0) ") }) { return true }
        return nil
    }

    static let negative = [
        "нет", "не", "неа", "не надо", "не нужно", "отмена", "отмени", "отменить", "стоп", "погоди", "подожди",
        "no", "nope", "cancel", "stop", "dont", "don t", "do not", "wait",
    ]

    /// Слова согласия. Специально нет слов, которые JARVIS сам произносит в вопросе
    /// («точно», «закрыть»), — чтобы собственный голос не сошёл за ответ.
    static let positive = [
        "да", "ага", "угу", "конечно", "давай", "подтверждаю", "верно", "выполняй", "делай", "закрывай",
        "ок", "окей", "хорошо", "можно", "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm",
        "do it", "go ahead",
    ]
}
