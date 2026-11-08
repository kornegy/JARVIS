/// Сообщения о ходе действия, которые не зависят от настроения: что не нашлось, что нужно
/// подтвердить, почему ничего не сделано. Подставляемые значения (`target`, `summary`) —
/// пользовательские данные: они только показываются и произносятся.
public enum ActionReply: Sendable, Equatable {
    case appNotFound(String)
    case siteNotFound(String)
    case notRunning(String)
    case protectedApp(String)
    case actionFailed(String)
    case unsupported
    /// Вопрос перед действием, которое можно подтвердить голосом.
    case confirmationQuestion(String)
    /// Действие, которое подтверждается только кнопкой или клавишей.
    case confirmationRequiredPhysically(String)
    case declined
    case timedOut
    case answerNotUnderstood
    case failure

    /// Русский текст. Вопрос подтверждения специально без слов «да»/«нет»: JARVIS не должен
    /// принять собственный голос за ответ.
    func russian(formal: Bool) -> String {
        switch self {
        case .appNotFound(let target): "Не нашёл приложение «\(target)»."
        case .siteNotFound(let target): "Не знаю сайт «\(target)». Скажи адрес, например «открой github.com»."
        case .notRunning(let target): "«\(target)» и так не запущено."
        case .protectedApp(let target): "«\(target)» закрывать не буду: без него macOS работает неправильно."
        case .actionFailed(let target):
            "Не получилось с «\(target)». Возможно, macOS ждёт разрешения: «Системные настройки → Конфиденциальность и безопасность → Автоматизация»."
        case .unsupported: "Это нельзя изменить для текущего устройства."
        case .confirmationQuestion(let summary): "Точно \(summary)?"
        case .confirmationRequiredPhysically(let summary):
            formal ? "Подтвердите в окне JARVIS: \(summary)." : "Подтверди в окне JARVIS: \(summary)."
        case .declined: formal ? "Хорошо, не буду." : "Хорошо, не делаю."
        case .timedOut: "Не дождался ответа — ничего не делаю."
        case .answerNotUnderstood: "Не расслышал ответ — ничего не делаю."
        case .failure: formal ? "Что-то пошло не так. Попробуйте ещё раз." : "Что-то пошло не так. Попробуй ещё раз."
        }
    }

    var english: String {
        switch self {
        case .appNotFound(let target): "I couldn't find an app called “\(target)”."
        case .siteNotFound(let target): "I don't know a website called “\(target)”. Try the address, like “open github.com”."
        case .notRunning(let target): "“\(target)” isn't running."
        case .protectedApp(let target): "I won't quit “\(target)”: macOS needs it."
        case .actionFailed(let target):
            "That didn't work for “\(target)”. macOS may be waiting for permission in System Settings → Privacy & Security → Automation."
        case .unsupported: "This can't be changed for the current device."
        case .confirmationQuestion(let summary): "Should I \(summary)?"
        case .confirmationRequiredPhysically(let summary): "Please confirm in the JARVIS window: \(summary)."
        case .declined: "Okay, I won't."
        case .timedOut: "No answer, so I'm not doing it."
        case .answerNotUnderstood: "I didn't catch that, so I'm not doing it."
        case .failure: "Something went wrong. Please try again."
        }
    }
}
