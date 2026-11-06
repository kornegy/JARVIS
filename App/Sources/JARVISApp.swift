import SwiftUI
import JarvisCore

enum WindowID {
    static let main = "main"
    static let activity = "activity"
}

/// Точка входа. JARVIS — «агент» (LSUIElement): без иконки в Dock, живёт в строке меню.
///
/// Сцены:
/// * `MenuBarExtra` — иконка состояния в строке меню и компактная панель управления;
/// * «JARVIS» — небольшое окно со статусом и последними действиями;
/// * «Журнал действий» — полный журнал аудита;
/// * `Settings` — стандартное окно настроек (⌘,).
@main
struct JARVISApp: App {
    @State private var model = AppModel(launchOptions: .current)

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: model)
        } label: {
            Image(systemName: model.state.presentation.symbolName)
                .accessibilityLabel(Text("JARVIS: \(model.state.presentation.title)"))
        }
        .menuBarExtraStyle(.window)

        Window("JARVIS", id: WindowID.main) {
            MainWindowView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.shouldPresentMainWindowAtLaunch ? .presented : .suppressed)

        Window("Журнал действий", id: WindowID.activity) {
            ActivityLogView(model: model)
        }
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(model: model)
        }
    }
}
