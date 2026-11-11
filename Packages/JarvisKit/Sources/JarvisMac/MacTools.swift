import JarvisTools

/// Инструменты macOS («руки» JARVIS). Регистрируются в общем реестре в приложении.
///
/// Phase 3a: приложения (открыть/закрыть), сайты и поиск в интернете, громкость.
public enum MacTools {
    public static func register(into registry: inout ToolRegistry, apps: AppCatalog = AppCatalog()) throws {
        try registry.register(OpenAppTool(catalog: apps))
        try registry.register(QuitAppTool(catalog: apps))
        try registry.register(OpenWebsiteTool())
        try registry.register(WebSearchTool())
        try registry.register(SetVolumeTool())
        try registry.register(ChangeVolumeTool())
        try registry.register(SetMutedTool())
    }
}
