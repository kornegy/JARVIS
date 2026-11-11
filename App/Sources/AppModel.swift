import AppKit
import Foundation
import Observation
import SwiftUI
import JarvisAI
import JarvisAssistant
import JarvisCore
import JarvisSettings
import JarvisMac
import JarvisTools
import JarvisVoice

/// Состояние приложения для интерфейса и «композиционный корень»: здесь создаются
/// и связываются модули — настройки, журнал, голосовые движки, оркестратор ассистента.
@MainActor
@Observable
final class AppModel {
    private(set) var settings: JarvisSettings
    private(set) var recentActivity: [AuditEntry] = []
    private(set) var notice: String?
    private(set) var hotKeyProblem: String? = nil

    let directories: AppDirectories
    let launchOptions: AppLaunchOptions
    let loginItem: LoginItemController
    let assistant: AssistantController
    /// Статусы разрешений macOS и их запрос (вкладка «Разрешения»).
    let permissions: PermissionManager

    private let settingsStore: SettingsStore
    private let auditLog: AuditLog
    private let speechInput: AppleSpeechInputEngine
    private let speechOutput: SystemSpeechSynthesizer
    private let hotKey = PushToTalkHotKey()
    private let confirmationPanel = ConfirmationPanelController()
    private let log = JarvisLogger(category: "app")
    @ObservationIgnored private var isPushToTalkHeld = false

    init(launchOptions: AppLaunchOptions) {
        // Имя главного потока — чтобы отличать его в разбивке «где тратится процессор».
        CPUProfiler.nameMainThread()
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
        let auditLog = AuditLog(
            directory: directories.auditDirectory,
            retentionDays: loaded.settings.privacy.auditRetentionDays,
            detailLevel: loaded.settings.privacy.auditDetail
        )

        // В UI-тестах «домашняя папка» для файловых команд — временная: тесты не трогают настоящие файлы.
        let files = launchOptions.isUITesting ? FileToolkit(home: directories.root) : FileToolkit()
        let permissions = PermissionManager(folders: files.access, policy: files.policy)
        var registry: ToolRegistry
        do {
            registry = try BuiltInTools.makeRegistry()
            try MacTools.register(into: &registry, files: files)
        } catch {
            logger.fault("Built-in tools failed to register", .error(error))
            registry = ToolRegistry()
        }
        let speechInput = AppleSpeechInputEngine()
        let speechOutput = SystemSpeechSynthesizer()

        self.launchOptions = launchOptions
        self.directories = directories
        self.settingsStore = store
        self.settings = loaded.settings
        self.auditLog = auditLog
        self.speechInput = speechInput
        self.speechOutput = speechOutput
        self.permissions = permissions
        self.assistant = AssistantController(
            settings: loaded.settings,
            speechInput: speechInput,
            speechOutput: speechOutput,
            microphone: MicrophonePermission(),
            speechRecognition: SpeechRecognitionPermission(),
            sounds: SystemFeedbackSounds(),
            processor: CommandProcessor(registry: registry, auditLog: auditLog, permissions: permissions),
            auditLog: auditLog
        )
        self.loginItem = LoginItemController(isManaged: !launchOptions.isUITesting)
        self.notice = startupNotice ?? AppModel.notice(for: loaded.origin)

        assistant.onPrivacyModeRequest = { [weak self] enabled, source in
            self?.update(source: source) { $0.privacy.privacyMode = enabled }
        }
        assistant.onActivityRecorded = { [weak self] in
            Task { await self?.refreshActivity() }
        }
        assistant.onConfirmationChanged = { [weak self] pending in
            self?.updateConfirmationPanel(pending)
        }
        hotKey.onPress = { [weak self] in self?.pushToTalkDown() }
        hotKey.onRelease = { [weak self] in self?.pushToTalkUp() }

        Task { await self.performMaintenance() }
    }

    // MARK: - Состояние

    var state: AssistantState { assistant.state }
    var isEnabled: Bool { state.isEnabled }
    var isMicrophoneCapturing: Bool { assistant.isMicrophoneCapturing }
    var isMicrophonePaused: Bool { assistant.machine.isMicrophonePaused }

    var shouldPresentMainWindowAtLaunch: Bool {
        launchOptions.forceShowMainWindow || settings.general.showMainWindowAtLaunch
    }

    var canToggleMicrophonePause: Bool {
        assistant.machine.canHandle(isMicrophonePaused ? .resumeMicrophone : .pauseMicrophone)
    }

    /// Подсказка, как обратиться к ассистенту.
    var voiceHint: String {
        let shortcut = settings.voice.pushToTalkShortcut.displayName
        switch settings.voice.listeningMode {
        case .pushToTalk:
            return "Удерживайте \(shortcut) и говорите — или нажмите «Говорить»."
        case .wakeWord:
            let phrase = settings.voice.wakePhrases.first.map { "«\($0.capitalized)»" } ?? "фразу-активатор"
            return "Скажите \(phrase) или удерживайте \(shortcut)."
        }
    }

    // MARK: - Действия пользователя

    func setEnabled(_ enabled: Bool) {
        Task {
            if enabled {
                await assistant.enable()
                registerHotKey()
            } else {
                await assistant.disable()
                hotKey.unregister()
            }
        }
    }

    func toggleMicrophonePause() {
        Task { await assistant.toggleMicrophonePause() }
    }

    /// Кнопка «Говорить» / «Стоп».
    func toggleTalking() {
        Task {
            if assistant.state == .listening {
                await assistant.cancelListening()
            } else {
                await assistant.startListening()
            }
        }
    }

    func submitCommand(_ text: String) {
        Task { await assistant.submitTypedCommand(text) }
    }

    /// Показать или спрятать окно подтверждения «Да / Нет».
    private func updateConfirmationPanel(_ pending: PendingAction?) {
        guard let pending else {
            confirmationPanel.hide()
            return
        }
        confirmationPanel.show(
            pending,
            onConfirm: { [weak self] in Task { await self?.assistant.confirmPendingAction() } },
            onDecline: { [weak self] in Task { await self?.assistant.declinePendingAction() } }
        )
    }

    func retryAssistant() {
        Task { await assistant.retry() }
    }

    func downloadSpeechModel() async {
        await assistant.downloadSpeechModel()
    }

    func requestSpeechRecognitionAccess() {
        Task { await assistant.requestSpeechRecognitionAccess() }
    }

    func speechModelStatus() async -> SpeechModelStatus {
        let configuration = SpeechInputConfiguration(
            locale: settings.voice.locale,
            modelPreference: settings.voice.recognitionModel
        )
        return await speechInput.modelStatus(for: configuration)
    }

    /// Какая модель распознавания сейчас слушает (для строки диагностики).
    var activeSpeechModelName: String? { assistant.activeSpeechModelName }

    /// Шапка отчёта о нагрузке: версия и настройки, от которых она зависит. Без личных данных.
    var diagnosticsContext: String {
        let mode = settings.voice.listeningMode == .wakeWord ? "фраза-активатор" : "Push-to-Talk"
        let live = settings.voice.showLiveTranscript ? "вкл" : "выкл"
        // «Слушаю», но модель ещё не назвалась — распознавание запускается (загрузка модели).
        let speechModel = activeSpeechModelName ?? (state == .listening ? "запускается" : "не слушает")
        return "JARVIS \(Bundle.main.versionDescription) · режим: \(mode) · модель: \(speechModel)"
            + " · живой текст: \(live) · состояние: \(state.presentation.title)"
    }

    func previewVoice() {
        let text = ResponseLanguage(locale: settings.voice.locale) == .english
            ? "Hi! This is how my voice sounds."
            : "Привет! Так звучит мой голос."
        let output = SpeechOutputSettings(
            locale: settings.voice.locale,
            voiceIdentifier: settings.voice.voiceIdentifier,
            rate: settings.voice.speechRate,
            volume: settings.voice.speechVolume
        )
        Task { await speechOutput.speak(text, settings: output) }
    }

    /// Пример ответа с текущим характером (для вкладки «Личность»).
    func sampleReply() -> String {
        var composer = ResponseComposer(
            personality: Personality(
                humor: settings.personality.humor,
                verbosity: settings.personality.verbosity,
                formality: settings.personality.formality
            ),
            language: ResponseLanguage(locale: settings.voice.locale)
        )
        return composer.reply(to: .greeting)
    }

    func openSystemPrivacySettings(for problem: AssistantProblem) {
        let anchor = problem == .speechRecognitionDenied ? "Privacy_SpeechRecognition" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// «Системные настройки → Звук» (там выбирается микрофон для всей системы).
    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([directories.root])
    }

    // MARK: - Push-to-Talk

    private func pushToTalkDown() {
        guard !isPushToTalkHeld else { return }
        isPushToTalkHeld = true
        Task {
            await assistant.pushToTalkPressed()
            // Клавишу могли отпустить, пока запускался микрофон.
            if !isPushToTalkHeld { assistant.pushToTalkReleased() }
        }
    }

    private func pushToTalkUp() {
        isPushToTalkHeld = false
        assistant.pushToTalkReleased()
    }

    private func registerHotKey() {
        guard !launchOptions.isUITesting, isEnabled else { return }
        do {
            try hotKey.register(settings.voice.pushToTalkShortcut)
            hotKeyProblem = nil
        } catch {
            log.error("Push-to-talk hotkey unavailable", .error(error))
            hotKeyProblem = "Сочетание \(settings.voice.pushToTalkShortcut.displayName) занято другим приложением. Выберите другое."
        }
    }

    // MARK: - Настройки

    /// Меняет настройки, сохраняет их и применяет к модулям.
    func update(source: CommandSource = .userInterface, _ change: (inout JarvisSettings) -> Void) {
        var updated = settings
        change(&updated)
        updated = updated.normalized()
        guard updated != settings else { return }

        let previous = settings
        settings = updated
        persistSettings()

        Task { await assistant.apply(settings: updated) }
        if updated.voice.pushToTalkShortcut != previous.voice.pushToTalkShortcut {
            registerHotKey()
        }
        if updated.privacy.auditRetentionDays != previous.privacy.auditRetentionDays
            || updated.privacy.auditDetail != previous.privacy.auditDetail {
            let auditLog = self.auditLog
            let retention = updated.privacy.auditRetentionDays
            let detail = updated.privacy.auditDetail
            Task { await auditLog.configure(retentionDays: retention, detailLevel: detail) }
        }
        if updated.privacy.privacyMode != previous.privacy.privacyMode {
            record(updated.privacy.privacyMode ? "privacy_mode.enable" : "privacy_mode.disable", source: source)
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

    private func record(_ action: ActionIdentifier, source: CommandSource) {
        let auditLog = self.auditLog
        Task {
            do {
                try await auditLog.record(AuditEvent(action: action, source: source))
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
