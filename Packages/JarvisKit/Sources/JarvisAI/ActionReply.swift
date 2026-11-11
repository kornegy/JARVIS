/// Раздел «Системных настроек», где пользователь даёт JARVIS разрешение.
public enum SettingsPane: Sendable, Equatable {
    case filesAndFolders
    case automation
    case accessibility
    case microphone
    case speechRecognition
    /// Остальные разрешения — общий раздел конфиденциальности.
    case privacy

    var russian: String {
        switch self {
        case .filesAndFolders: "«Системные настройки → Конфиденциальность и безопасность → Файлы и папки»"
        case .automation: "«Системные настройки → Конфиденциальность и безопасность → Автоматизация»"
        case .accessibility: "«Системные настройки → Конфиденциальность и безопасность → Универсальный доступ»"
        case .microphone: "«Системные настройки → Конфиденциальность и безопасность → Микрофон»"
        case .speechRecognition: "«Системные настройки → Конфиденциальность и безопасность → Распознавание речи»"
        case .privacy: "«Системные настройки → Конфиденциальность и безопасность»"
        }
    }

    var english: String {
        switch self {
        case .filesAndFolders: "System Settings → Privacy & Security → Files & Folders"
        case .automation: "System Settings → Privacy & Security → Automation"
        case .accessibility: "System Settings → Privacy & Security → Accessibility"
        case .microphone: "System Settings → Privacy & Security → Microphone"
        case .speechRecognition: "System Settings → Privacy & Security → Speech Recognition"
        case .privacy: "System Settings → Privacy & Security"
        }
    }
}

/// Сообщения о ходе действия, которые не зависят от настроения: что не нашлось, что нужно
/// подтвердить, почему ничего не сделано. Подставляемые значения (`target`, `summary`, имена
/// файлов) — пользовательские данные: они только показываются и произносятся.
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

    // Файлы (Phase 3b).
    /// Файлов по описанию нет. Пустая строка — описание без названия («последний PDF»).
    case fileNotFound(String)
    case folderNotFound(String)
    /// Системная, скрытая или стандартная папка — JARVIS её не трогает.
    case protectedFile(String)
    /// Файл запускает программу (скрипт, установщик) — JARVIS его не открывает.
    case unsafeToOpen(String)
    case fileActionFailed(String)
    /// В папке назначения уже есть файл с таким именем — ничего не перезаписывается.
    case alreadyExists(String)
    /// macOS не дала доступ к папке.
    case noFolderAccess(String)
    case permissionNeeded(SettingsPane)
    case nothingToUndo
    /// «Открой его», но JARVIS ещё ничего не находил.
    case noRecentFiles
    /// «Открой пятый», а в списке три файла.
    case noSuchItem(available: Int)
    /// Нашлось несколько файлов, а действие — над одним: какой?
    case whichFile(names: [String], total: Int)
    /// «Найди файл» без подробностей.
    case needFileDescription
    case needDestination
    case needNewName
    case tooManyFiles(limit: Int)
    /// Переименовать можно только один файл.
    case onlyOneFile

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

        case .fileNotFound(let target):
            target.isEmpty ? "Таких файлов не нашёл." : "Не нашёл файлов «\(target)»."
        case .folderNotFound(let target): "Не нашёл папку «\(target)»."
        case .protectedFile(let target):
            "С «\(target)» работать не буду: это системная, скрытая или стандартная папка macOS."
        case .unsafeToOpen(let target):
            "«\(target)» запускает программу — такие файлы я не открываю. Если доверяешь ему, открой сам в Finder."
        case .fileActionFailed(let target): "Не получилось с «\(target)»."
        case .alreadyExists(let target): "Там уже есть «\(target)» — ничего не перезаписываю."
        case .noFolderAccess(let target):
            "macOS не дала доступ к папке «\(target)». Разрешить можно в \(SettingsPane.filesAndFolders.russian)."
        case .permissionNeeded(let pane): "Нужно разрешение: \(pane.russian)."
        case .nothingToUndo: "Отменять нечего: с файлами я пока ничего не делал."
        case .noRecentFiles:
            formal
                ? "Сначала найдите файл: например, «найди последний скачанный PDF»."
                : "Сначала найди файл: например, «найди последний скачанный PDF»."
        case .noSuchItem(let available): "В списке только \(RussianPlural.files(available))."
        case .whichFile(let names, let total):
            "Нашёл \(RussianPlural.files(total)): \(Self.russianList(names, total: total)). Какой из них? Скажи «первый», «второй»…"
        case .needFileDescription:
            "Какой файл? Скажи, например, «найди последний скачанный PDF» или «открой файл отчёт»."
        case .needDestination: "Куда? Скажи, например, «перемести его в Документы»."
        case .needNewName: "Как назвать? Скажи, например, «переименуй его в Отчёт за март»."
        case .tooManyFiles(let limit): "Слишком много файлов — больше \(limit). Уточни, какие."
        case .onlyOneFile: "Это можно сделать только с одним файлом. Скажи, с каким."
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

        case .fileNotFound(let target):
            target.isEmpty ? "I couldn't find any matching files." : "I couldn't find any files called “\(target)”."
        case .folderNotFound(let target): "I couldn't find a folder called “\(target)”."
        case .protectedFile(let target): "I won't touch “\(target)”: it's a system, hidden or standard macOS folder."
        case .unsafeToOpen(let target):
            "“\(target)” runs a program, so I don't open files like that. If you trust it, open it yourself in Finder."
        case .fileActionFailed(let target): "That didn't work for “\(target)”."
        case .alreadyExists(let target): "There's already a “\(target)” there, so I'm not overwriting anything."
        case .noFolderAccess(let target): "macOS didn't allow access to “\(target)”. You can allow it in \(SettingsPane.filesAndFolders.english)."
        case .permissionNeeded(let pane): "I need permission: \(pane.english)."
        case .nothingToUndo: "There's nothing to undo."
        case .noRecentFiles: "Find a file first, for example: “find the latest PDF I downloaded”."
        case .noSuchItem(let available): "There are only \(available) in the list."
        case .whichFile(let names, let total):
            "I found \(total): \(Self.englishList(names, total: total)). Which one? Say “the first one”, “the second one”…"
        case .needFileDescription: "Which file? For example: “find the latest PDF I downloaded”."
        case .needDestination: "Where to? For example: “move it to Documents”."
        case .needNewName: "What should I call it? For example: “rename it to March report”."
        case .tooManyFiles(let limit): "That's too many files — more than \(limit). Please narrow it down."
        case .onlyOneFile: "I can only do that with one file. Which one?"
        }
    }

    /// «a», «b» и «c» (и ещё 5).
    static func russianList(_ names: [String], total: Int) -> String {
        let quoted = names.map { "«\($0)»" }
        var text: String
        switch quoted.count {
        case 0: text = ""
        case 1: text = quoted[0]
        default: text = quoted.dropLast().joined(separator: ", ") + " и " + (quoted.last ?? "")
        }
        if total > names.count { text += " (и ещё \(total - names.count))" }
        return text
    }

    static func englishList(_ names: [String], total: Int) -> String {
        let quoted = names.map { "“\($0)”" }
        var text: String
        switch quoted.count {
        case 0: text = ""
        case 1: text = quoted[0]
        default: text = quoted.dropLast().joined(separator: ", ") + " and " + (quoted.last ?? "")
        }
        if total > names.count { text += " (and \(total - names.count) more)" }
        return text
    }
}
