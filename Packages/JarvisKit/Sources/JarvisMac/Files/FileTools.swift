import AppKit
import JarvisAI
import JarvisCore
import JarvisTools

/// Всё для работы с файлами: политика путей, поиск, журнал отмены, доступ к папкам.
/// Инструменты получают один общий набор — так «отмени» видит действия всех инструментов.
public final class FileToolkit: Sendable {
    public let policy: PathPolicy
    public let access: FolderAccessMonitor
    public let journal: UndoJournal
    let finder: FileFinder
    let operations: FileOperations
    let opener: @MainActor @Sendable (URL) -> Bool
    let revealer: @MainActor @Sendable ([URL]) -> Void

    public convenience init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(policy: PathPolicy(home: home))
    }

    init(
        policy: PathPolicy,
        useSpotlight: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current,
        trasher: @escaping @Sendable (URL) throws -> URL = FileOperations.systemTrasher,
        opener: @escaping @MainActor @Sendable (URL) -> Bool = { url in Workspace.openFile(url) },
        revealer: @escaping @MainActor @Sendable ([URL]) -> Void = { urls in Workspace.reveal(urls) }
    ) {
        let access = FolderAccessMonitor()
        let journal = UndoJournal()
        self.policy = policy
        self.access = access
        self.journal = journal
        self.finder = FileFinder(policy: policy, access: access, useSpotlight: useSpotlight, now: now, calendar: calendar)
        self.operations = FileOperations(policy: policy, journal: journal, access: access, trasher: trasher)
        self.opener = opener
        self.revealer = revealer
    }

    /// Инструменты Phase 3b.
    var tools: [any Tool] {
        [
            FindFilesTool(kit: self), OpenFileTool(kit: self), RevealFilesTool(kit: self), MoveFilesTool(kit: self),
            RenameFileTool(kit: self), TrashFilesTool(kit: self), UndoTool(kit: self),
        ]
    }
}

extension Workspace {
    /// Открыть файл в программе по умолчанию, папку — в Finder.
    @MainActor
    static func openFile(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    /// Показать файлы в Finder (выделить).
    @MainActor
    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// Тяжёлую работу с диском (поиск) — не на главном потоке и не на общих потоках Swift.
enum Background {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

// MARK: - Аргументы

private func paths(_ arguments: ValidatedArguments, _ name: String = "paths") -> [URL] {
    (arguments.list(name) ?? []).compactMap { value in
        if case .string(let path) = value { return URL(filePath: path) }
        return nil
    }
}

private func path(_ arguments: ValidatedArguments, _ name: String = "path") -> URL? {
    arguments.text(name).map { URL(filePath: $0) }
}

private let pathsParameter = ParameterSpec(
    name: "paths",
    summary: "Абсолютные пути к файлам",
    type: .list(.filePath, maxCount: StandardTools.maxFilesPerAction)
)

/// В журнал — только количество файлов, без имён (имена могут быть личными).
private func auditCount(_ count: Int) -> AuditDetail? {
    AuditDetail("files: \(count)")
}

/// Фразы про файлы на двух языках.
enum FilePhrases {
    static func quoted(_ name: String, _ locale: Locale) -> String {
        Phrasing.quoted(name, locale)
    }

    /// «3 файла» / «3 files».
    static func count(_ count: Int, _ locale: Locale, folders: Bool = false) -> String {
        if Phrasing.isEnglish(locale) {
            let noun = folders ? (count == 1 ? "folder" : "folders") : (count == 1 ? "file" : "files")
            return "\(count) \(noun)"
        }
        return folders
            ? "\(count) " + RussianPlural.form(count, one: "папку", few: "папки", many: "папок")
            : RussianPlural.files(count)
    }

    /// Имя для ответа: у папки — как в Finder, у файла — настоящее имя с расширением.
    static func name(_ url: URL, isFolder: Bool) -> String {
        isFolder ? FileNames.folder(url) : FileNames.file(url)
    }

    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// «сегодня в 14:05», «вчера в 9:12», «12 ноября».
    static func when(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let english = Phrasing.isEnglish(locale)
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return english ? "today at \(time)" : "сегодня в \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return english ? "yesterday at \(time)" : "вчера в \(time)"
        }
        return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.wide))
    }

    /// «a», «b» и «c».
    static func list(_ names: [String], _ locale: Locale) -> String {
        let english = Phrasing.isEnglish(locale)
        let items = names.map { Phrasing.quoted($0, locale) }
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + (english ? " and " : " и ") + last
    }
}

// MARK: - Найти

/// «Найди последний скачанный PDF». Категория 1: только имена и даты, содержимое не читается.
struct FindFilesTool: Tool {
    let kit: FileToolkit

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.findFiles,
            summary: "Найти файлы в домашней папке по названию, типу, папке и дате (содержимое не читается).",
            parameters: [
                ParameterSpec(name: "name", summary: "Слова из названия", type: .text(maxLength: 100), isRequired: false),
                ParameterSpec(name: "kind", summary: "Тип файла", type: .choice(FileKind.allCases.map(\.rawValue)), isRequired: false),
                ParameterSpec(
                    name: "location",
                    summary: "Стандартная папка",
                    type: .choice(FileLocation.allCases.map(\.rawValue)),
                    isRequired: false
                ),
                ParameterSpec(name: "period", summary: "Период", type: .choice(FilePeriod.allCases.map(\.rawValue)), isRequired: false),
                ParameterSpec(name: "latest", summary: "Сначала самые новые", type: .boolean, isRequired: false),
                ParameterSpec(
                    name: "limit",
                    summary: "Сколько файлов вернуть",
                    type: .integer(1...(StandardTools.maxFilesPerAction + 1)),
                    isRequired: false
                ),
            ],
            risk: .safe,
            requiredPermissions: [.filesAndFolders],
            effect: .readOnly,
            producesUntrustedContent: true
        )
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let request = FileSearchRequest(
            name: arguments.text("name"),
            kind: arguments.text("kind").flatMap(FileKind.init(rawValue:)),
            location: arguments.text("location").flatMap(FileLocation.init(rawValue:)),
            period: arguments.text("period").flatMap(FilePeriod.init(rawValue:)),
            latest: arguments.boolean("latest") ?? false,
            limit: arguments.integer("limit") ?? 20
        )
        let finder = kit.finder
        let result = await Background.run { finder.search(request) }
        guard let first = result.files.first else {
            if let denied = result.deniedFolders.first { throw ToolFailure.accessDenied(target: FileNames.folder(denied)) }
            throw ToolFailure.notFound(target: request.name ?? "")
        }
        let message = Self.message(result, first: first, request: request, finder: finder, locale: context.locale)
        return ToolOutcome(
            message: message,
            untrustedContent: UntrustedText(message),
            auditDetail: auditCount(result.total),
            files: result.files.map { $0.url.path }
        )
    }

    static func message(_ result: FileSearchResult, first: FoundFile, request: FileSearchRequest, finder: FileFinder, locale: Locale) -> String {
        let english = Phrasing.isEnglish(locale)
        let folders = result.files.allSatisfy(\.isDirectory)
        let firstName = FilePhrases.quoted(FilePhrases.name(first.url, isFolder: first.isDirectory), locale)
        let parentURL = first.url.deletingLastPathComponent()
        let parent = parentURL.standardizedFileURL.path == finder.policy.home.path
            ? (english ? "your home folder" : "домашней папке")
            : FilePhrases.quoted(FileNames.folder(parentURL), locale)
        let place = english ? "in \(parent)" : (parent.hasPrefix("«") ? "в папке \(parent)" : "в \(parent)")

        if result.total == 1 {
            return english ? "I found \(firstName) \(place)." : "Нашёл \(firstName) \(place)."
        }
        let total = FilePhrases.count(result.total, locale, folders: folders)
        if request.latest {
            let when = FilePhrases.when(first.date, now: finder.now(), calendar: finder.calendar, locale: locale)
            return english
                ? "The newest is \(firstName) \(place), \(when). \(total) in total."
                : "Самый свежий — \(firstName) \(place), \(when). Всего нашёл \(total)."
        }
        let names = result.files.prefix(3).map { FilePhrases.name($0.url, isFolder: $0.isDirectory) }
        let list = FilePhrases.list(Array(names), locale)
        if result.total <= 3 {
            return english ? "I found \(total): \(list)." : "Нашёл \(total): \(list)."
        }
        return english ? "I found \(total). Here are the first ones: \(list)." : "Нашёл \(total). Вот первые: \(list)."
    }
}

// MARK: - Открыть и показать

/// «Открой его», «открой загрузки». Категория 1. Файлы, которые запускают программы
/// (скрипты, установщики, приложения), JARVIS не открывает.
struct OpenFileTool: Tool {
    let kit: FileToolkit

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.openFile,
            summary: "Открыть файл в программе по умолчанию или папку в Finder.",
            parameters: [ParameterSpec(name: "path", summary: "Абсолютный путь", type: .filePath)],
            risk: .safe,
            requiredPermissions: [.filesAndFolders],
            effect: .local
        )
    }

    func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String {
        let (url, isFolder) = try check(arguments)
        let name = FilePhrases.quoted(FilePhrases.name(url, isFolder: isFolder), context.locale)
        return Phrasing.isEnglish(context.locale) ? "open \(name)" : "открыть \(name)"
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let (url, isFolder) = try check(arguments)
        let name = FilePhrases.name(url, isFolder: isFolder)
        guard await kit.opener(url) else { throw ToolFailure.actionFailed(target: name) }
        return ToolOutcome(message: FilePhrases.quoted(name, context.locale), auditDetail: auditCount(1))
    }

    private func check(_ arguments: ValidatedArguments) throws -> (URL, Bool) {
        guard let url = path(arguments) else { throw ToolFailure.notFound(target: "") }
        try kit.operations.checkReadable(url)
        let isFolder = FilePhrases.isFolder(url)
        let isExecutable = FileManager.default.isExecutableFile(atPath: url.path)
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if PathPolicy.isUnsafeToOpen(url, isDirectory: isDirectory, isExecutable: isExecutable) {
            throw ToolFailure.unsafeToOpen(target: FileNames.file(url))
        }
        return (url, isFolder)
    }
}

/// «Покажи его в Finder». Категория 1.
struct RevealFilesTool: Tool {
    let kit: FileToolkit

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.revealFiles,
            summary: "Показать файлы в Finder.",
            parameters: [pathsParameter],
            risk: .safe,
            requiredPermissions: [.filesAndFolders],
            effect: .local
        )
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let urls = paths(arguments)
        guard let first = urls.first else { throw ToolFailure.notFound(target: "") }
        for url in urls { try kit.operations.checkReadable(url) }
        await kit.revealer(urls)
        let message = urls.count == 1
            ? FilePhrases.quoted(FilePhrases.name(first, isFolder: FilePhrases.isFolder(first)), context.locale)
            : FilePhrases.count(urls.count, context.locale)
        return ToolOutcome(message: message, auditDetail: auditCount(urls.count))
    }
}

// MARK: - Переместить и переименовать

/// «Перемести его в Документы». Категория 2 (больше 10 файлов — категория 3). Можно отменить.
struct MoveFilesTool: Tool {
    let kit: FileToolkit

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.moveFiles,
            summary: "Переместить файлы в другую папку (без перезаписи).",
            parameters: [pathsParameter, ParameterSpec(name: "destination", summary: "Папка назначения", type: .filePath)],
            risk: .consequential,
            requiredPermissions: [.filesAndFolders],
            effect: .local,
            isUndoable: true
        )
    }

    func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String {
        let (moves, folder) = try plan(arguments)
        let english = Phrasing.isEnglish(context.locale)
        let destination = FilePhrases.quoted(FileNames.folder(folder), context.locale)
        guard moves.count == 1, let move = moves.first else {
            let count = FilePhrases.count(moves.count, context.locale)
            return english ? "move \(count) to \(destination)" : "переместить \(count) в \(destination)"
        }
        let name = FilePhrases.quoted(FileNames.file(move.from), context.locale)
        let source = FilePhrases.quoted(FileNames.folder(move.from.deletingLastPathComponent()), context.locale)
        return english ? "move \(name) from \(source) to \(destination)" : "переместить \(name) из \(source) в \(destination)"
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let (moves, folder) = try plan(arguments)
        let moved = try kit.operations.perform(moves, kind: .move)
        let english = Phrasing.isEnglish(context.locale)
        let destination = FilePhrases.quoted(FileNames.folder(folder), context.locale)
        let what = moves.count == 1
            ? FilePhrases.quoted(FileNames.file(moves[0].from), context.locale)
            : FilePhrases.count(moves.count, context.locale)
        return ToolOutcome(
            message: english ? "\(what) to \(destination)" : "\(what) в \(destination)",
            auditDetail: auditCount(moved.count),
            files: moved.map(\.path)
        )
    }

    private func plan(_ arguments: ValidatedArguments) throws -> ([FileMove], URL) {
        guard let folder = path(arguments, "destination") else { throw ToolFailure.notFound(target: "") }
        return (try kit.operations.planMove(paths(arguments), to: folder), folder)
    }
}

/// «Переименуй его в Отчёт за март». Категория 2. Расширение сохраняется. Можно отменить.
struct RenameFileTool: Tool {
    let kit: FileToolkit

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.renameFile,
            summary: "Переименовать файл или папку (расширение сохраняется, без перезаписи).",
            parameters: [
                ParameterSpec(name: "path", summary: "Абсолютный путь", type: .filePath),
                ParameterSpec(name: "newName", summary: "Новое имя", type: .text(maxLength: 200)),
            ],
            risk: .consequential,
            requiredPermissions: [.filesAndFolders],
            effect: .local,
            isUndoable: true
        )
    }

    func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String {
        let move = try plan(arguments)
        let old = FilePhrases.quoted(FileNames.file(move.from), context.locale)
        let new = FilePhrases.quoted(FileNames.file(move.to), context.locale)
        return Phrasing.isEnglish(context.locale) ? "rename \(old) to \(new)" : "переименовать \(old) в \(new)"
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let move = try plan(arguments)
        let renamed = try kit.operations.perform([move], kind: .rename)
        return ToolOutcome(
            message: FilePhrases.quoted(FileNames.file(move.to), context.locale),
            auditDetail: auditCount(1),
            files: renamed.map(\.path)
        )
    }

    private func plan(_ arguments: ValidatedArguments) throws -> FileMove {
        guard let url = path(arguments), let newName = arguments.text("newName") else { throw ToolFailure.notFound(target: "") }
        return try kit.operations.planRename(url, to: newName)
    }
}

// MARK: - Корзина

/// «Удали его». Категория 3: только в Корзину, подтверждение по умолчанию — кнопкой.
/// Можно отменить («Джарвис, отмени» вернёт файл из Корзины на место).
struct TrashFilesTool: Tool {
    let kit: FileToolkit

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.trashFiles,
            summary: "Переместить файлы в Корзину (не удаляет окончательно).",
            parameters: [pathsParameter],
            risk: .dangerous,
            requiredPermissions: [.filesAndFolders],
            effect: .local,
            isUndoable: true
        )
    }

    func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String {
        let urls = try plan(arguments)
        let english = Phrasing.isEnglish(context.locale)
        let what = urls.count == 1
            ? FilePhrases.quoted(FileNames.file(urls[0]), context.locale)
            : FilePhrases.count(urls.count, context.locale)
        return english ? "move \(what) to the Trash" : "переместить в Корзину \(what)"
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let urls = try plan(arguments)
        let trashed = try kit.operations.trash(urls)
        let what = urls.count == 1
            ? FilePhrases.quoted(FileNames.file(urls[0]), context.locale)
            : FilePhrases.count(urls.count, context.locale)
        return ToolOutcome(message: what, auditDetail: auditCount(trashed.count), files: [])
    }

    private func plan(_ arguments: ValidatedArguments) throws -> [URL] {
        let urls = paths(arguments)
        guard !urls.isEmpty else { throw ToolFailure.notFound(target: "") }
        try kit.operations.planTrash(urls)
        return urls
    }
}

// MARK: - Отмена

/// «Джарвис, отмени». Возвращает последнее действие с файлами: перемещение, переименование,
/// Корзину. Категория 2 (это тоже перемещение файлов).
struct UndoTool: Tool {
    let kit: FileToolkit

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: StandardTools.undo,
            summary: "Отменить последнее действие JARVIS с файлами.",
            risk: .consequential,
            requiredPermissions: [.filesAndFolders],
            effect: .local
        )
    }

    func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String {
        let entry = try kit.operations.planUndo()
        let english = Phrasing.isEnglish(context.locale)
        guard entry.moves.count == 1, let move = entry.moves.first else {
            let count = FilePhrases.count(entry.moves.count, context.locale)
            return english ? "put \(count) back" : "вернуть на место \(count)"
        }
        let name = FilePhrases.quoted(FileNames.file(move.from), context.locale)
        let folder = FilePhrases.quoted(FileNames.folder(move.from.deletingLastPathComponent()), context.locale)
        switch entry.kind {
        case .trash:
            return english ? "restore \(name) from the Trash to \(folder)" : "вернуть \(name) из Корзины в \(folder)"
        case .move:
            return english ? "move \(name) back to \(folder)" : "вернуть \(name) обратно в \(folder)"
        case .rename:
            let current = FilePhrases.quoted(FileNames.file(move.to), context.locale)
            return english ? "rename \(current) back to \(name)" : "вернуть файлу \(current) прежнее имя \(name)"
        }
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        let entry = try kit.operations.planUndo()
        let restored = try kit.operations.undo(entry)
        let english = Phrasing.isEnglish(context.locale)
        let message: String
        if restored.count == 1, let url = restored.first {
            let name = FilePhrases.quoted(FileNames.file(url), context.locale)
            let folder = FilePhrases.quoted(FileNames.folder(url.deletingLastPathComponent()), context.locale)
            switch entry.kind {
            case .rename:
                message = english ? "the name is \(name) again" : "файлу возвращено имя \(name)"
            case .move, .trash:
                message = english ? "\(name) is back in \(folder)" : "\(name) снова лежит в \(folder)"
            }
        } else {
            let count = FilePhrases.count(restored.count, context.locale)
            message = english ? "\(count) are back where they were" : "\(count) снова на своих местах"
        }
        return ToolOutcome(message: message, auditDetail: auditCount(restored.count), files: restored.map(\.path))
    }
}
