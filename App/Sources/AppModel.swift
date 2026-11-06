import AppKit
import Foundation
import Observation
import SwiftUI
import JarvisCore
import JarvisSettings

/// Состояние приложения для интерфейса и «композиционный корень»: здесь создаются
/// и связываются модули (настройки, журнал, машина состояний).
///
/// В Phase 1 голосового движка нет, поэтому включение JARVIS меняет только состояние и
/// пишет событие в журнал — микрофон не открывается (см. `isMicrophoneCapturing`).
@MainActor
@Observable
final class AppModel {
    private(set) var stateMachine: AssistantStateMachine
    private(set) var settings: JarvisSettings
    private(set) var recentActivity: [AuditEntry] = []
    private(set) var notice: String?

    let directories: AppDirectories
    let launchOptions: AppLaunchOptions
    let loginItem: LoginItemController

    /// Голосовой движок появится в Phase 2.
    let isVoiceEngineAvailable = false

    private let settingsStore: SettingsStore
    private let auditLog: AuditLog
    private let log = JarvisLogger(category: "app")

    init(launchOptions: AppLaunchOptions) {
        let logger = JarvisLogger(category: "app")
        let directories = launchOptions.isUITesting
            ? AppDirectories(root: FileManager.default.temporaryDirectory.appending(path: "JARVIS-UITests-\(UUID().uuidString)", directoryHint: .isDirectory))
            : AppDirectories.standard()

        var startupNotice: String?
        do {
            try directories.prepare()
        } catch {
            logger.error("Could not prepare data directory", .error(error))
            startupNotice = "Не удалось подготовить папку данных. Настройки и журнал могут не сохраниться."
        }

        let store = SettingsStore(fileURL: directories.settingsFile, backupsDirectory: directories.backupsDirectory)
        let loaded = store.load()

        self.launchOptions = launchOptions
        self.directories = directories
        self.settingsStore = store
        self.settings = loaded.settings
        self.stateMachine = AssistantStateMachine(listeningMode: loaded.settings.voice.listeningMode)
        self.auditLog = AuditLog(
            directory: directories.auditDirectory,
            retentionDays: loaded.settings.privacy.auditRetentionDays,
            detailLevel: loaded.settings.privacy.auditDetail
        )
        self.loginItem = LoginItemController(isManaged: !launchOptions.isUITesting)
        self.notice = startupNotice ?? AppModel.notice(for: loaded.origin)

        Task { await self.performMaintenance() }
    }

    // MARK: - Состояние

    var state: AssistantState { stateMachine.state }
    var isEnabled: Bool { state.isEnabled }

    /// Реально ли сейчас идёт захват звука. В Phase 1 — никогда.
    var isMicrophoneCapturing: Bool { false }

    var shouldPresentMainWindowAtLaunch: Bool {
        launchOptions.forceShowMainWindow || settings.general.showMainWindowAtLaunch
    }

    var canToggleMicrophonePause: Bool {
        stateMachine.canHandle(stateMachine.isMicrophonePaused ? .resumeMicrophone : .pauseMicrophone)
    }

    // MARK: - Действия пользователя

    func setEnabled(_ enabled: Bool) {
        guard stateMachine.handle(enabled ? .enable : .disable) else { return }
        if enabled {
            log.notice("Assistant enabled")
            record("assistant.enable")
        } else {
            log.notice("Assistant disabled")
            record("assistant.disable")
        }
    }

    func toggleMicrophonePause() {
        let pausing = !stateMachine.isMicrophonePaused
        guard stateMachine.handle(pausing ? .pauseMicrophone : .resumeMicrophone) else { return }
        record(pausing ? "microphone.pause" : "microphone.resume")
    }

    func dismissNotice() {
        notice = nil
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([directories.root])
    }

    // MARK: - Настройки

    /// Меняет настройки, сохраняет их и применяет к модулям.
    func update(_ change: (inout JarvisSettings) -> Void) {
        var updated = settings
        change(&updated)
        updated = updated.normalized()
        guard updated != settings else { return }

        let previous = settings
        settings = updated
        persistSettings()

        if updated.voice.listeningMode != previous.voice.listeningMode {
            stateMachine.handle(.setListeningMode(updated.voice.listeningMode))
        }
        if updated.privacy.auditRetentionDays != previous.privacy.auditRetentionDays
            || updated.privacy.auditDetail != previous.privacy.auditDetail {
            let auditLog = self.auditLog
            let retention = updated.privacy.auditRetentionDays
            let detail = updated.privacy.auditDetail
            Task { await auditLog.configure(retentionDays: retention, detailLevel: detail) }
        }
        if updated.privacy.privacyMode != previous.privacy.privacyMode {
            record(updated.privacy.privacyMode ? "privacy_mode.enable" : "privacy_mode.disable")
        }
    }

    /// Binding для SwiftUI-контролов, который сохраняет изменение через `update`.
    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<JarvisSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func persistSettings() {
        do {
            try settingsStore.save(settings)
        } catch SettingsStoreError.refusingToOverwriteNewerSchema(_) {
            notice = "Настройки созданы более новой версией JARVIS — изменения не сохраняются, чтобы их не потерять."
        } catch {
            log.error("Settings save failed", .error(error))
            notice = "Не удалось сохранить настройки."
        }
    }

    // MARK: - Журнал действий

    func refreshActivity() async {
        do {
            recentActivity = try await auditLog.recentEntries(limit: 500)
        } catch {
            log.error("Audit read failed", .error(error))
        }
    }

    func clearActivity() async {
        do {
            try await auditLog.clearAll()
            recentActivity = []
            log.notice("Audit log cleared")
        } catch {
            log.error("Audit clear failed", .error(error))
            notice = "Не удалось очистить журнал действий."
        }
    }

    private func record(_ action: ActionIdentifier) {
        let auditLog = self.auditLog
        Task {
            do {
                try await auditLog.record(AuditEvent(action: action, source: .userInterface))
            } catch {
                log.error("Audit record failed", .error(error))
            }
            await refreshActivity()
        }
    }

    private func performMaintenance() async {
        do {
            let removed = try await auditLog.purgeExpired()
            if removed > 0 { log.info("Expired audit files removed", .int("count", removed)) }
        } catch {
            log.error("Audit purge failed", .error(error))
        }
        await refreshActivity()
    }

    private static func notice(for origin: SettingsOrigin) -> String? {
        switch origin {
        case .defaults, .file:
            nil
        case .migrated:
            "Настройки обновлены до новой версии. Резервная копия сохранена в папке backups."
        case .recoveredFromCorruption:
            "Файл настроек был повреждён — восстановлены значения по умолчанию. Старый файл сохранён в папке backups."
        case .newerSchema:
            "Настройки созданы более новой версией JARVIS — изменения не будут сохраняться."
        }
    }
}
