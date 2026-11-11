import AppKit
import ApplicationServices
import Observation
import JarvisAI
import JarvisAssistant
import JarvisMac
import JarvisTools
import JarvisVoice

/// Permission Manager (docs/Security.md §4): статусы всех разрешений macOS в одном месте,
/// объяснения «зачем» и «что будет без него», запрос и переход в «Системные настройки».
///
/// Разрешения запрашиваются только по необходимости: микрофон — при первом прослушивании,
/// папки — при первом обращении к ним, «Автоматизация» — при первом закрытии приложения.
/// Здесь — только по кнопке пользователя. Обходить отказ JARVIS не пытается.
@MainActor
@Observable
final class PermissionManager: PermissionChecking {
    /// Меняется после любой проверки — интерфейс перерисовывает статусы.
    private(set) var revision = 0

    @ObservationIgnored private let microphone = MicrophonePermission()
    @ObservationIgnored private let speechRecognition = SpeechRecognitionPermission()
    @ObservationIgnored private let folders: FolderAccessMonitor
    @ObservationIgnored private let policy: PathPolicy

    init(folders: FolderAccessMonitor, policy: PathPolicy) {
        self.folders = folders
        self.policy = policy
    }

    // MARK: - Статус

    func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:
            return Self.status(microphone.state)
        case .speechRecognition:
            return Self.status(speechRecognition.state)
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .filesAndFolders:
            let states = FolderAccessMonitor.protectedLocations.map { folders.state(for: $0) }
            if states.allSatisfy({ $0 == .denied }) { return .denied }
            if states.allSatisfy({ $0 == .granted }) { return .granted }
            return .unknown
        case .appleEvents, .calendars, .reminders, .notifications, .location:
            // «Автоматизация» спрашивается для каждого приложения отдельно; остальное JARVIS пока не использует.
            return .unknown
        }
    }

    func folderStatus(_ location: FileLocation) -> FolderAccessState {
        folders.state(for: location)
    }

    /// Обновить статусы (окно настроек открыли, пользователь вернулся из «Системных настроек»).
    func refresh() {
        revision += 1
    }

    // MARK: - Запрос

    /// Попросить разрешение. macOS покажет свой запрос, только если ещё не спрашивала;
    /// после отказа — открываем нужный раздел «Системных настроек».
    func request(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            if microphone.state == .notDetermined { _ = await microphone.request() } else { openSystemSettings(for: kind) }
        case .speechRecognition:
            if speechRecognition.state == .notDetermined { _ = await speechRecognition.request() } else { openSystemSettings(for: kind) }
        case .filesAndFolders:
            for location in FolderAccessMonitor.protectedLocations {
                await checkFolder(location)
            }
        case .accessibility, .appleEvents, .calendars, .reminders, .notifications, .location:
            openSystemSettings(for: kind)
        }
        refresh()
    }

    /// Проверить доступ к папке: JARVIS читает список её файлов (только имена). Если macOS ещё
    /// не спрашивала — покажет запрос.
    func checkFolder(_ location: FileLocation) async {
        let folders = self.folders
        let policy = self.policy
        _ = await Task.detached(priority: .userInitiated) { folders.probe(location, policy: policy) }.value
        refresh()
    }

    func openSystemSettings(for kind: PermissionKind) {
        let anchor = switch kind {
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        case .accessibility: "Privacy_Accessibility"
        case .appleEvents: "Privacy_Automation"
        case .filesAndFolders: "Privacy_FilesAndFolders"
        case .calendars: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .notifications: "Privacy"
        case .location: "Privacy_LocationServices"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func status(_ state: PermissionState) -> PermissionStatus {
        switch state {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        }
    }
}
