import JarvisTools

/// Инструменты macOS («руки» JARVIS). Регистрируются в общем реестре в приложении.
///
/// Phase 3a: приложения (открыть/закрыть), сайты и поиск в интернете, громкость.
/// Phase 3b: файлы (найти, открыть, показать, переместить, переименовать, в Корзину, отменить).
public enum MacTools {
    public static func register(
        into registry: inout ToolRegistry,
        apps: AppCatalog = AppCatalog(),
        files: FileToolkit = FileToolkit()
    ) throws {
        for tool in files.tools {
            try registry.register(tool)
        }
        try registry.register(OpenAppTool(catalog: apps))
        try registry.register(QuitAppTool(catalog: apps))
        try registry.register(OpenWebsiteTool())
        try registry.register(WebSearchTool())
        try registry.register(SetVolumeTool())
        try registry.register(ChangeVolumeTool())
        try registry.register(SetMutedTool())
    }
}
