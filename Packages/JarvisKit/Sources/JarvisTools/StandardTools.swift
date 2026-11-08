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

    /// Поисковые системы для `web.search`.
    public static let searchEngines = ["google", "yandex", "duckduckgo", "bing"]
}
