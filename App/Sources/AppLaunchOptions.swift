import Foundation

/// Параметры запуска. Используются UI-тестами:
/// * `--ui-testing` — данные во временной папке, автозапуск не трогается;
/// * `--show-main-window` — показать главное окно независимо от настроек.
struct AppLaunchOptions: Sendable {
    let isUITesting: Bool
    let forceShowMainWindow: Bool

    static var current: AppLaunchOptions {
        let arguments = ProcessInfo.processInfo.arguments
        return AppLaunchOptions(
            isUITesting: arguments.contains("--ui-testing"),
            forceShowMainWindow: arguments.contains("--show-main-window")
        )
    }
}
