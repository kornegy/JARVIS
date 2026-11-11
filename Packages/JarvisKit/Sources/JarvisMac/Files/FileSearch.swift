import CoreServices
import Foundation
import JarvisAI

/// Что искать (уже проверенные аргументы инструмента `files.find`).
struct FileSearchRequest: Sendable, Equatable {
    var name: String?
    var kind: FileKind?
    var location: FileLocation?
    var period: FilePeriod?
    var latest = false
    var limit = 20
}

/// Найденный файл.
struct FoundFile: Sendable, Equatable {
    let url: URL
    let isDirectory: Bool
    /// Когда файл последний раз появился или менялся (что позже: добавлен в папку или изменён).
    let date: Date
    /// Насколько имя подходит к запросу (`FileNameMatcher.score`).
    let score: Int
}

struct FileSearchResult: Sendable {
    /// Лучшие результаты (не больше `limit`).
    let files: [FoundFile]
    /// Сколько всего подошло.
    let total: Int
    /// Папки, к которым macOS не дала доступ.
    let deniedFolders: [URL]
}

/// Поиск файлов: Spotlight, а если он ничего не дал (индекс выключен или не готов) — обход
/// стандартных папок с ограничением глубины и числа файлов.
///
/// Ищет только в домашней папке, всё найденное проходит через `PathPolicy`. Содержимое файлов
/// не читается — только имена, типы (по расширению) и даты.
public final class FileFinder: Sendable {
    let policy: PathPolicy
    let access: FolderAccessMonitor
    private let useSpotlight: Bool
    let now: @Sendable () -> Date
    let calendar: Calendar

    /// Больше файлов за один обход папок не просматривается.
    static let scanLimit = 30_000
    static let spotlightLimit = 2_000

    public init(
        policy: PathPolicy = PathPolicy(),
        access: FolderAccessMonitor = FolderAccessMonitor(),
        useSpotlight: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.policy = policy
        self.access = access
        self.useSpotlight = useSpotlight
        self.now = now
        self.calendar = calendar
    }

    func search(_ request: FileSearchRequest) -> FileSearchResult {
        var denied: [URL] = []
        var matches: [FoundFile] = []

        if request.location == nil, useSpotlight, let query = Self.spotlightQuery(for: request),
           let urls = SpotlightSearch.paths(matching: query, in: policy.home, maxCount: Self.spotlightLimit) {
            matches = evaluate(urls, request)
        }
        if matches.isEmpty {
            let scan = DirectoryScanner.scan(scopes(for: request), policy: policy, limit: Self.scanLimit)
            denied = scan.denied
            for folder in scan.readable { access.record(folder, policy: policy, state: .granted) }
            for folder in scan.denied { access.record(folder, policy: policy, state: .denied) }
            matches = evaluate(scan.urls, request)
        }

        let sorted = matches.sorted { lhs, rhs in
            if !request.latest, request.name != nil, lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.url.path < rhs.url.path
        }
        return FileSearchResult(files: Array(sorted.prefix(request.limit)), total: sorted.count, deniedFolders: denied)
    }

    // MARK: - Где искать

    /// Папки для обхода и глубина: в названной папке — поглубже, без папки — стандартные места.
    func scopes(for request: FileSearchRequest) -> [DirectoryScanner.Scope] {
        if let location = request.location {
            let depth = location == .home ? 1 : 4
            return [DirectoryScanner.Scope(url: policy.url(for: location.folderName), depth: depth)]
        }
        return [
            DirectoryScanner.Scope(url: policy.url(for: FileLocation.desktop.folderName), depth: 3),
            DirectoryScanner.Scope(url: policy.url(for: FileLocation.downloads.folderName), depth: 3),
            DirectoryScanner.Scope(url: policy.url(for: FileLocation.documents.folderName), depth: 4),
            DirectoryScanner.Scope(url: policy.url(for: FileLocation.pictures.folderName), depth: 2),
            DirectoryScanner.Scope(url: policy.home, depth: 0),
        ]
    }

    // MARK: - Подходит ли файл

    func evaluate(_ urls: [URL], _ request: FileSearchRequest) -> [FoundFile] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey, .contentModificationDateKey, .addedToDirectoryDateKey,
        ]
        let window = period(request.period)
        var seen = Set<String>()
        var result: [FoundFile] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), policy.allows(url, for: .read) else { continue }
            seen.insert(path)
            guard let values = try? url.resourceValues(forKeys: keys), values.isHidden != true else { continue }
            let isFolder = values.isDirectory == true && values.isPackage != true
            guard Self.matches(kind: request.kind, url: url, isFolder: isFolder) else { continue }
            let score = FileNameMatcher.score(fileName: url.lastPathComponent, query: request.name ?? "")
            guard score > 0 else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let date = max(modified, values.addedToDirectoryDate ?? .distantPast)
            if let window, !window.contains(date) { continue }
            result.append(FoundFile(url: url, isDirectory: isFolder, date: date, score: score))
        }
        return result
    }

    private func period(_ period: FilePeriod?) -> DateInterval? {
        guard let period else { return nil }
        let current = now()
        let startOfToday = calendar.startOfDay(for: current)
        switch period {
        case .today:
            return DateInterval(start: startOfToday, end: max(current, startOfToday))
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return DateInterval(start: start, end: startOfToday)
        case .week:
            let start = calendar.date(byAdding: .day, value: -7, to: current) ?? startOfToday
            return DateInterval(start: start, end: current)
        }
    }

    /// Тип файла — по расширению: одинаково для Spotlight и обхода папок, без чтения содержимого.
    static let extensions: [FileKind: Set<String>] = [
        .pdf: ["pdf"],
        .image: ["jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp", "raw", "cr2", "nef", "arw", "dng", "svg"],
        .video: ["mov", "mp4", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"],
        .audio: ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "ogg", "opus", "caf"],
        .document: ["pdf", "doc", "docx", "pages", "rtf", "rtfd", "txt", "odt", "md"],
        .presentation: ["key", "ppt", "pptx", "odp"],
        .spreadsheet: ["numbers", "xls", "xlsx", "csv", "ods", "tsv"],
        .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"],
    ]

    /// Так macOS называет скриншоты (на разных языках системы).
    static let screenshotPrefixes = ["снимок экрана", "screenshot", "screen shot", "bildschirmfoto", "capture d"]

    static func matches(kind: FileKind?, url: URL, isFolder: Bool) -> Bool {
        guard let kind else { return true }
        switch kind {
        case .folder:
            return isFolder
        case .screenshot:
            let name = url.lastPathComponent.lowercased()
            return !isFolder && (extensions[.image] ?? []).contains(url.pathExtension.lowercased())
                && screenshotPrefixes.contains { name.hasPrefix($0) }
        default:
            return !isFolder && (extensions[kind] ?? []).contains(url.pathExtension.lowercased())
        }
    }

    // MARK: - Spotlight

    /// Запрос Spotlight. Слова запроса — только буквы и цифры (после нормализации), поэтому
    /// «вставить» в запрос что-то своё нельзя. `nil` — искать по нему нечего (нет ни названия,
    /// ни типа): тогда обходим папки.
    static func spotlightQuery(for request: FileSearchRequest) -> String? {
        var parts: [String] = []
        for forms in FileNameMatcher.searchForms(request.name ?? "") {
            let safe = forms.filter { form in !form.isEmpty && form.allSatisfy { $0.isLetter || $0.isNumber } }
            guard !safe.isEmpty else { continue }
            parts.append("(" + safe.map { "kMDItemFSName == \"*\($0)*\"cd" }.joined(separator: " || ") + ")")
        }
        if let kind = request.kind {
            switch kind {
            case .folder:
                parts.append("kMDItemContentType == \"public.folder\"")
            case .screenshot:
                parts.append("kMDItemIsScreenCapture == 1")
            default:
                let names = (extensions[kind] ?? []).sorted().map { "kMDItemFSName == \"*.\($0)\"c" }
                if !names.isEmpty { parts.append("(" + names.joined(separator: " || ") + ")") }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }
}

/// Синхронный запрос к Spotlight (CoreServices `MDQuery`) — выполняется вне главного потока.
enum SpotlightSearch {
    /// Пути найденных файлов; `nil` — Spotlight недоступен.
    static func paths(matching query: String, in scope: URL, maxCount: Int) -> [URL]? {
        let created: MDQuery? = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil)
        guard let mdQuery = created else { return nil }
        MDQuerySetSearchScope(mdQuery, [scope.path] as CFArray, 0)
        MDQuerySetMaxCount(mdQuery, maxCount)
        // 1 = kMDQuerySynchronous: дождаться результатов, без обновлений «на лету».
        guard MDQueryExecute(mdQuery, CFOptionFlags(1)) else { return nil }
        MDQueryStop(mdQuery)
        let count = MDQueryGetResultCount(mdQuery)
        var urls: [URL] = []
        urls.reserveCapacity(count)
        for index in 0..<count {
            let raw: UnsafeRawPointer? = MDQueryGetResultAtIndex(mdQuery, index)
            guard let raw else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            let value: CFTypeRef? = MDItemCopyAttribute(item, kMDItemPath)
            if let path = value as? String {
                urls.append(URL(filePath: path))
            }
        }
        return urls
    }
}

/// Обход папок без Spotlight: в ширину, с ограничением глубины и общего числа файлов.
/// Скрытые файлы, содержимое «пакетов» и ссылки на папки не обходятся.
enum DirectoryScanner {
    struct Scope: Sendable, Equatable {
        let url: URL
        let depth: Int
    }

    struct Result: Sendable {
        var urls: [URL] = []
        /// Корневые папки, которые удалось прочитать.
        var readable: [URL] = []
        /// Корневые папки, к которым macOS не дала доступ.
        var denied: [URL] = []
    }

    static func scan(_ scopes: [Scope], policy: PathPolicy, limit: Int) -> Result {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        var queue: [(url: URL, level: Int, depth: Int)] = scopes.map { ($0.url, 0, $0.depth) }
        var next = 0
        var visited = Set<String>()
        var result = Result()

        while next < queue.count, result.urls.count < limit {
            let (directory, level, depth) = queue[next]
            next += 1
            let items: [URL]
            do {
                items = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            } catch {
                if level == 0, isPermissionError(error) { result.denied.append(directory) }
                continue
            }
            if level == 0 { result.readable.append(directory) }
            for item in items where result.urls.count < limit {
                let path = item.standardizedFileURL.path
                guard !visited.contains(path), policy.allows(item, for: .read) else { continue }
                visited.insert(path)
                result.urls.append(item)
                let values = try? item.resourceValues(forKeys: Set(keys))
                if level < depth, values?.isDirectory == true, values?.isPackage != true, values?.isSymbolicLink != true {
                    queue.append((item, level + 1, depth))
                }
            }
        }
        return result
    }

    /// macOS не дала доступ (разрешение «Файлы и папки» или права на папку).
    static func isPermissionError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        let posix = (nsError.domain == NSPOSIXErrorDomain ? nsError : nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
        guard let posix, posix.domain == NSPOSIXErrorDomain else { return false }
        return posix.code == Int(EPERM) || posix.code == Int(EACCES)
    }
}
