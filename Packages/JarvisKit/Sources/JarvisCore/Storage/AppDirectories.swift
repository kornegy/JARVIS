import Foundation

/// Где JARVIS хранит свои данные. Всё — в одной папке, чтобы пользователь мог
/// посмотреть или удалить данные целиком.
///
/// По умолчанию: `~/Library/Application Support/JARVIS/` (права 0700).
public struct AppDirectories: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Стандартное расположение для текущего пользователя.
    public static func standard() -> AppDirectories {
        AppDirectories(root: URL.applicationSupportDirectory.appending(path: "JARVIS", directoryHint: .isDirectory))
    }

    public var settingsFile: URL { root.appending(path: "settings.json", directoryHint: .notDirectory) }
    public var auditDirectory: URL { root.appending(path: "audit", directoryHint: .isDirectory) }
    public var backupsDirectory: URL { root.appending(path: "backups", directoryHint: .isDirectory) }

    /// Создаёт папки (если их нет) и выставляет права «только владелец».
    public func prepare() throws {
        for directory in [root, auditDirectory, backupsDirectory] {
            try SecureFileIO.createPrivateDirectory(at: directory)
        }
    }
}
