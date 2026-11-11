import Foundation
import JarvisTools
import Synchronization

/// Перемещение одного файла: откуда и куда.
struct FileMove: Sendable, Equatable {
    let from: URL
    let to: URL
}

/// Действие с файлами, которое можно отменить.
struct UndoEntry: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case move
        case rename
        case trash
    }

    let id: UUID
    let kind: Kind
    let moves: [FileMove]
}

/// Журнал отмены: что JARVIS сделал с файлами в этой сессии (docs/Security.md §5).
///
/// Только в памяти: после выхода из JARVIS журнал пуст. Хранит последние 20 действий;
/// «Джарвис, отмени» возвращает последнее.
public final class UndoJournal: Sendable {
    public static let capacity = 20
    private let entries = Mutex<[UndoEntry]>([])

    public init() {}

    public var count: Int { entries.withLock { $0.count } }

    func record(_ entry: UndoEntry) {
        guard !entry.moves.isEmpty else { return }
        entries.withLock { list in
            list.append(entry)
            if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        }
    }

    func last() -> UndoEntry? {
        entries.withLock { $0.last }
    }

    /// Убрать запись (действие отменено) или оставить только то, что ещё не возвращено.
    func replace(_ id: UUID, remaining moves: [FileMove]) {
        entries.withLock { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            if moves.isEmpty {
                list.remove(at: index)
            } else {
                list[index] = UndoEntry(id: id, kind: list[index].kind, moves: moves)
            }
        }
    }

    public func clear() {
        entries.withLock { $0.removeAll() }
    }
}

/// Операции с файлами. Сначала всё проверяется (`plan…`), потом выполняется: если хоть один
/// файл нельзя трогать или в папке назначения уже есть файл с таким именем — не делается
/// ничего. Ничего не перезаписывается; «удалить» — только в Корзину.
struct FileOperations: Sendable {
    let policy: PathPolicy
    let journal: UndoJournal
    let access: FolderAccessMonitor
    /// Переместить в Корзину; возвращает, где файл оказался (в тестах — подделка).
    let trasher: @Sendable (URL) throws -> URL

    static let systemTrasher: @Sendable (URL) throws -> URL = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let trashed = resulting.map({ $0 as URL }) else { throw CocoaError(.fileNoSuchFile) }
        return trashed
    }

    // MARK: - Проверки

    /// Файл существует, и политика разрешает его менять.
    func checkModifiable(_ url: URL) throws {
        guard exists(url) else { throw ToolFailure.notFound(target: FileNames.file(url)) }
        guard policy.allows(url, for: .modify) else { throw ToolFailure.protectedTarget(target: FileNames.file(url)) }
    }

    func checkReadable(_ url: URL) throws {
        guard policy.allows(url, for: .read) else { throw ToolFailure.protectedTarget(target: FileNames.file(url)) }
        guard exists(url) else { throw ToolFailure.notFound(target: FileNames.file(url)) }
    }

    func checkDestination(_ folder: URL) throws {
        guard policy.allows(folder, for: .destination) else { throw ToolFailure.protectedTarget(target: FileNames.folder(folder)) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolFailure.notFound(target: FileNames.folder(folder))
        }
    }

    // MARK: - Перемещение

    func planMove(_ urls: [URL], to folder: URL) throws -> [FileMove] {
        try checkDestination(folder)
        let folderPath = folder.standardizedFileURL.path
        var moves: [FileMove] = []
        var targets = Set<String>()
        for url in urls {
            try checkModifiable(url)
            let sourcePath = url.standardizedFileURL.path
            // Уже лежит в этой папке.
            if url.deletingLastPathComponent().standardizedFileURL.path == folderPath { continue }
            // Папку нельзя положить в саму себя.
            if folderPath == sourcePath || folderPath.hasPrefix(sourcePath + "/") {
                throw ToolFailure.actionFailed(target: FileNames.file(url))
            }
            let destination = folder.appending(path: url.lastPathComponent)
            let key = destination.standardizedFileURL.path.lowercased()
            if exists(destination) || targets.contains(key) {
                throw ToolFailure.alreadyExists(target: FileNames.file(url))
            }
            targets.insert(key)
            moves.append(FileMove(from: url, to: destination))
        }
        guard !moves.isEmpty else { throw ToolFailure.alreadyExists(target: urls.first.map(FileNames.file) ?? "") }
        return moves
    }

    // MARK: - Переименование

    func planRename(_ url: URL, to rawName: String) throws -> FileMove {
        try checkModifiable(url)
        let newName = try Self.validatedName(rawName, keepingExtensionOf: url)
        let destination = url.deletingLastPathComponent().appending(path: newName)
        guard destination.lastPathComponent != url.lastPathComponent else {
            throw ToolFailure.alreadyExists(target: newName)
        }
        if !Self.differsOnlyInCase(url, destination), exists(destination) {
            throw ToolFailure.alreadyExists(target: newName)
        }
        return FileMove(from: url, to: destination)
    }

    /// Новое имя: без «/» и «:» (macOS их не допускает), не скрытое (без точки в начале);
    /// расширение файла сохраняется — иначе файл перестанет открываться.
    static func validatedName(_ raw: String, keepingExtensionOf url: URL) throws -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix("."), name.utf8.count <= 240,
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw ToolFailure.actionFailed(target: raw)
        }
        let currentExtension = url.pathExtension
        if !currentExtension.isEmpty, (name as NSString).pathExtension.lowercased() != currentExtension.lowercased() {
            name += "." + currentExtension
        }
        return name
    }

    // MARK: - Корзина

    func planTrash(_ urls: [URL]) throws {
        for url in urls { try checkModifiable(url) }
    }

    // MARK: - Выполнение

    /// Выполнить перемещения и записать в журнал отмены то, что удалось.
    func perform(_ moves: [FileMove], kind: UndoEntry.Kind) throws -> [URL] {
        var done: [FileMove] = []
        defer { journal.record(UndoEntry(id: UUID(), kind: kind, moves: done)) }
        for move in moves {
            try relocate(move.from, to: move.to)
            done.append(move)
        }
        return done.map(\.to)
    }

    func trash(_ urls: [URL]) throws -> [URL] {
        var done: [FileMove] = []
        defer { journal.record(UndoEntry(id: UUID(), kind: .trash, moves: done)) }
        for url in urls {
            do {
                let trashed = try trasher(url)
                done.append(FileMove(from: url, to: trashed))
            } catch {
                throw failure(for: error, at: url)
            }
        }
        return done.map(\.to)
    }

    // MARK: - Отмена

    /// Последнее действие и проверка, что его можно вернуть: файл на месте, прежнее место
    /// свободно и разрешено политикой.
    func planUndo() throws -> UndoEntry {
        guard let entry = journal.last() else { throw ToolFailure.nothingToUndo }
        for move in entry.moves {
            guard exists(move.to) else { throw ToolFailure.notFound(target: FileNames.file(move.from)) }
            if !Self.differsOnlyInCase(move.from, move.to), exists(move.from) {
                throw ToolFailure.alreadyExists(target: FileNames.file(move.from))
            }
            guard policy.allows(move.from, for: .modify) else { throw ToolFailure.protectedTarget(target: FileNames.file(move.from)) }
            let currentAllowed = entry.kind == .trash ? Self.isInTrash(move.to) : policy.allows(move.to, for: .modify)
            guard currentAllowed else { throw ToolFailure.protectedTarget(target: FileNames.file(move.to)) }
            let parent = move.from.deletingLastPathComponent()
            guard exists(parent) else { throw ToolFailure.notFound(target: FileNames.folder(parent)) }
        }
        return entry
    }

    func undo(_ entry: UndoEntry) throws -> [URL] {
        var remaining = entry.moves
        var restored: [URL] = []
        defer { journal.replace(entry.id, remaining: remaining) }
        while let move = remaining.last {
            try relocate(move.to, to: move.from)
            remaining.removeLast()
            restored.insert(move.from, at: 0)
        }
        return restored
    }

    // MARK: - Вспомогательное

    /// Переместить без перезаписи. Смена только регистра букв («отчет» → «Отчет») на обычном
    /// диске Mac — через временное имя: для macOS это одно и то же имя.
    private func relocate(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        do {
            if Self.differsOnlyInCase(source, destination) {
                let temporary = source.deletingLastPathComponent().appending(path: ".jarvis-rename-\(UUID().uuidString)")
                try fileManager.moveItem(at: source, to: temporary)
                do {
                    try fileManager.moveItem(at: temporary, to: destination)
                } catch {
                    try? fileManager.moveItem(at: temporary, to: source)
                    throw error
                }
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        } catch {
            throw failure(for: error, at: source)
        }
    }

    private func failure(for error: any Error, at url: URL) -> ToolFailure {
        if DirectoryScanner.isPermissionError(error) {
            access.record(url, policy: policy, state: .denied)
            return .accessDenied(target: FileNames.folder(url.deletingLastPathComponent()))
        }
        return .actionFailed(target: FileNames.file(url))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func differsOnlyInCase(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.path
        let right = rhs.standardizedFileURL.path
        return left != right && left.lowercased() == right.lowercased()
    }

    /// Файл в Корзине (своей или на внешнем диске).
    static func isInTrash(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        return parts.contains(".Trash") || parts.contains(".Trashes")
    }
}

/// Имена файлов и папок для ответов. Имя файла — недоверенные данные: в ответ попадает без
/// управляющих символов и не длиннее 80 знаков. В журнал не пишется.
enum FileNames {
    static let maxLength = 80

    static func file(_ url: URL) -> String {
        sanitize(url.lastPathComponent)
    }

    /// Имя папки как в Finder («Загрузки» на русской macOS).
    static func folder(_ url: URL) -> String {
        sanitize(FileManager.default.displayName(atPath: url.path))
    }

    static func sanitize(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars
            .map { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength - 1)) + "…"
    }
}
