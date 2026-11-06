import Observation
import ServiceManagement
import JarvisCore

/// Автозапуск при входе в систему через `SMAppService` (официальный механизм macOS 13+).
/// Пользователь видит JARVIS в «Системные настройки → Основные → Объекты входа».
@MainActor
@Observable
final class LoginItemController {
    private(set) var status: SMAppService.Status
    private(set) var lastErrorMessage: String?

    /// В UI-тестах автозапуск не трогаем.
    let isManaged: Bool

    private let log = JarvisLogger(category: "login-item")

    init(isManaged: Bool) {
        self.isManaged = isManaged
        self.status = isManaged ? SMAppService.mainApp.status : .notRegistered
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        guard isManaged else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastErrorMessage = nil
        } catch {
            log.error("Login item change failed", .error(error))
            lastErrorMessage = "Не удалось изменить автозапуск: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
