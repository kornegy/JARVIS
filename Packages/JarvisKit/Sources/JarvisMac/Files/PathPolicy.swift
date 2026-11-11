import Foundation

/// Политика путей (docs/Security.md §7): с какими файлами JARVIS вообще работает.
///
/// * Только домашняя папка пользователя — **кроме** `~/Library` (настройки и данные программ,
///   Keychain, почта) и скрытых папок (`.ssh`, `.gnupg`, `.config`, `.Trash`…).
/// * Стандартные папки («Документы», «Загрузки», «Рабочий стол»…) можно открыть и класть в них
///   файлы, но нельзя переместить, переименовать или удалить их самих.
/// * Внутрь «пакетов» (`.app`, библиотека «Фото», документ Pages) JARVIS не лезет: пакет —
///   это один документ, его можно переместить целиком.
/// * Ссылки (symlink) проверяются дважды: и сам путь, и куда он на самом деле ведёт. Ссылка
///   с рабочего стола на `/etc` не даст выйти за пределы домашней папки.
///
/// Чистая логика без обращения к диску — полностью покрыта тестами.
public struct PathPolicy: Sendable {
    public enum Access: Sendable {
        /// Найти, открыть, показать в Finder.
        case read
        /// Переместить, переименовать, удалить в Корзину.
        case modify
        /// Положить в эту папку.
        case destination
    }

    public let home: URL
    private let resolvedHome: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
        self.resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Стандартные папки macOS в домашней папке (имена на диске — всегда английские).
    static let standardFolders: Set<String> = [
        "desktop", "documents", "downloads", "pictures", "music", "movies", "public", "applications", "sites",
    ]

    /// Папки-«пакеты»: в Finder это один файл.
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "logicx", "band", "xcodeproj", "xcworkspace", "playground", "pages", "numbers", "key", "rtfd",
    ]

    /// Можно ли работать с путём.
    public func allows(_ url: URL, for access: Access) -> Bool {
        let literal = url.standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let literalParts = Self.components(of: literal, under: home) ?? Self.components(of: literal, under: resolvedHome)
        let resolvedParts = Self.components(of: resolved, under: resolvedHome) ?? Self.components(of: resolved, under: home)
        return Self.check(literalParts, access) && Self.check(resolvedParts, access)
    }

    /// Путь к стандартной папке («Загрузки») внутри домашней.
    public func url(for folderName: String?) -> URL {
        guard let folderName else { return home }
        return home.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Компоненты пути внутри `root`; `nil` — путь вне его.
    static func components(of url: URL, under root: URL) -> [String]? {
        let path = url.pathComponents
        let rootPath = root.pathComponents
        guard path.count >= rootPath.count, Array(path.prefix(rootPath.count)) == rootPath else { return nil }
        return Array(path.dropFirst(rootPath.count))
    }

    static func check(_ components: [String]?, _ access: Access) -> Bool {
        guard let components else { return false }
        if components.contains(where: { $0.hasPrefix(".") }) { return false }
        if components.first?.lowercased() == "library" { return false }
        switch access {
        case .read:
            return true
        case .destination:
            return !insidePackage(components, includingLast: true)
        case .modify:
            guard let first = components.first else { return false }
            if components.count == 1, standardFolders.contains(first.lowercased()) { return false }
            return !insidePackage(components, includingLast: false)
        }
    }

    private static func insidePackage(_ components: [String], includingLast: Bool) -> Bool {
        let ancestors = includingLast ? components : Array(components.dropLast())
        return ancestors.contains { packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    // MARK: - Файлы, которые запускают программы

    /// Расширения файлов, которые при открытии запускают код или устанавливают программы.
    static let unsafeExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish", "py", "rb", "pl", "php", "jar", "pkg",
        "mpkg", "workflow", "action", "scpt", "scptd", "applescript", "terminal", "exec", "bin", "run", "osax",
        "prefpane", "kext", "plugin", "dylib", "so", "bundle", "fileloc", "inetloc", "webloc", "url", "saver", "qlgenerator",
        "mobileconfig", "configprofile",
    ]

    /// Открытие файла запустит программу: скрипт, установщик, приложение, ссылку на что-то.
    /// Такие файлы JARVIS не открывает — пользователь открывает их сам (docs/Security.md §7).
    public static func isUnsafeToOpen(_ url: URL, isDirectory: Bool, isExecutable: Bool) -> Bool {
        if unsafeExtensions.contains(url.pathExtension.lowercased()) { return true }
        // Исполняемый файл без расширения откроется в Терминале и выполнится.
        return !isDirectory && isExecutable
    }
}
