import Foundation
import JarvisAI
import Synchronization

/// Установленное приложение.
public struct InstalledApp: Sendable, Equatable {
    public let url: URL
    public let bundleIdentifier: String?
    /// Имя для ответа пользователю — как в Finder, на языке системы («Заметки»).
    public let displayName: String
    /// Все имена для поиска: локализованное, из Info.plist, имя файла.
    public let names: [String]
}

/// Каталог установленных приложений.
///
/// Читает только стандартные папки приложений — это не требует разрешений macOS.
/// Результат кешируется на несколько минут; если приложение не нашлось, каталог один раз
/// пересканирует папки (вдруг его только что установили).
public final class AppCatalog: Sendable {
    private struct Cache {
        var apps: [InstalledApp] = []
        var loadedAt: Date?
    }

    private let directories: [URL]
    private let extraApps: [URL]
    private let maxAge: TimeInterval
    private let cache = Mutex(Cache())

    public init(
        directories: [URL] = AppCatalog.standardDirectories,
        extraApps: [URL] = AppCatalog.standardExtraApps,
        maxAge: TimeInterval = 300
    ) {
        self.directories = directories
        self.extraApps = extraApps
        self.maxAge = maxAge
    }

    public static var standardDirectories: [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            URL(filePath: "/Applications/Utilities", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications/Utilities", directoryHint: .isDirectory),
            // Safari и часть системных приложений на новых macOS лежат в защищённом «криптексе»,
            // а в /Applications — только ссылка (или её нет вовсе).
            URL(filePath: "/System/Cryptexes/App/System/Applications", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    /// Приложения вне стандартных папок, которые тоже открывают голосом.
    public static var standardExtraApps: [URL] {
        [URL(filePath: "/System/Library/CoreServices/Finder.app", directoryHint: .isDirectory)]
    }

    /// Все приложения (из кеша, если он свежий).
    public func apps(refresh: Bool = false) -> [InstalledApp] {
        let now = Date()
        if !refresh, let cached = cache.withLock({ state -> [InstalledApp]? in
            guard let loadedAt = state.loadedAt, now.timeIntervalSince(loadedAt) < maxAge else { return nil }
            return state.apps
        }) {
            return cached
        }
        let scanned = Self.scan(directories: directories, extraApps: extraApps)
        cache.withLock { state in
            state.apps = scanned
            state.loadedAt = now
        }
        return scanned
    }

    /// Приложение по тому, как его назвал пользователь.
    public func find(_ spokenName: String) -> InstalledApp? {
        if let app = Self.match(spokenName, in: apps()) { return app }
        return Self.match(spokenName, in: apps(refresh: true))
    }

    static func match(_ spokenName: String, in apps: [InstalledApp]) -> InstalledApp? {
        let candidates = apps.map { AppNameCandidate(id: $0.url.path, names: $0.names) }
        guard let best = AppNameMatcher.bestMatch(for: spokenName, in: candidates) else { return nil }
        return apps.first { $0.url.path == best.id }
    }

    static func scan(directories: [URL], extraApps: [URL]) -> [InstalledApp] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var result: [InstalledApp] = []

        func add(_ url: URL) {
            // Ссылка и настоящее приложение — одно и то же приложение.
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !seen.contains(path), let app = makeApp(at: url) else { return }
            seen.insert(path)
            result.append(app)
        }

        for directory in directories {
            guard let items = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    // Папки вроде «Microsoft Office» — на один уровень глубже.
                    let nested = (try? fileManager.contentsOfDirectory(
                        at: item,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    nested.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        extraApps.filter { fileManager.fileExists(atPath: $0.path) }.forEach(add)
        return result
    }

    static func makeApp(at url: URL) -> InstalledApp? {
        let fileName = url.deletingPathExtension().lastPathComponent
        let displayName = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let localized = bundle?.localizedInfoDictionary ?? [:]

        var names: [String] = []
        for name in [
            displayName,
            localized["CFBundleDisplayName"] as? String,
            localized["CFBundleName"] as? String,
            info["CFBundleDisplayName"] as? String,
            info["CFBundleName"] as? String,
            fileName,
        ] {
            guard let name, !name.isEmpty,
                  !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            names.append(name)
        }
        guard !names.isEmpty else { return nil }
        return InstalledApp(
            url: url,
            bundleIdentifier: bundle?.bundleIdentifier,
            displayName: displayName.isEmpty ? fileName : displayName,
            names: names
        )
    }
}
