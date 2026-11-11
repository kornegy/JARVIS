/// Имена стандартных инструментов. Реализации живут в платформенных модулях
/// (`JarvisMac`), а оркестратор ссылается на них по имени — так ядро не зависит от macOS.
public enum StandardTools {
    /// Открыть приложение (или переключиться на него). Параметр `name`.
    public static let openApp: ToolName = "apps.open"
    /// Закрыть приложение. Параметр `name`.
    public static let quitApp: ToolName = "apps.quit"
    /// Открыть сайт в браузере по умолчанию. Параметр `url`.
    public static let openWebsite: ToolName = "web.open"
    /// Поиск в интернете. Параметры `query`, `engine`.
    public static let webSearch: ToolName = "web.search"
    /// Громкость 0…100. Параметр `level`.
    public static let setVolume: ToolName = "system.volume.set"
    /// Громче/тише на `delta` (−100…100).
    public static let changeVolume: ToolName = "system.volume.change"
    /// Выключить/включить звук. Параметр `muted`.
    public static let setMuted: ToolName = "system.volume.mute"

    /// Найти файлы. Параметры `name`, `kind`, `location`, `period`, `latest`, `limit`.
    public static let findFiles: ToolName = "files.find"
    /// Открыть файл или папку. Параметр `path`.
    public static let openFile: ToolName = "files.open"
    /// Показать файлы в Finder. Параметр `paths`.
    public static let revealFiles: ToolName = "files.reveal"
    /// Переместить файлы в папку. Параметры `paths`, `destination`.
    public static let moveFiles: ToolName = "files.move"
    /// Переименовать файл. Параметры `path`, `newName`.
    public static let renameFile: ToolName = "files.rename"
    /// Переместить файлы в Корзину. Параметр `paths`.
    public static let trashFiles: ToolName = "files.trash"
    /// Отменить последнее действие с файлами («Джарвис, отмени»).
    public static let undo: ToolName = "actions.undo"

    /// Инструменты, которые работают с файлами (для понятных ответов об ошибках).
    public static let fileTools: Set<ToolName> = [findFiles, openFile, revealFiles, moveFiles, renameFile, trashFiles, undo]

    /// Больше файлов за одно действие JARVIS не трогает — пусть пользователь уточнит запрос.
    public static let maxFilesPerAction = 100

    /// Поисковые системы для `web.search`.
    public static let searchEngines = ["google", "yandex", "duckduckgo", "bing"]
}
