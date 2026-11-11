import Foundation
import Testing
import JarvisAI
import JarvisCore
import JarvisTools
@testable import JarvisMac

/// Временная «домашняя папка» со стандартными папками и файлами — тесты не трогают настоящие файлы.
private struct SandboxHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "JarvisMacTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        for folder in ["Desktop", "Documents", "Downloads", "Pictures", "Library", ".ssh", ".Trash", "Documents/Work"] {
            try FileManager.default.createDirectory(at: url.appending(path: folder), withIntermediateDirectories: true)
        }
    }

    @discardableResult
    func file(_ path: String, contents: String = "test") throws -> URL {
        let file = url.appending(path: path)
        try Data(contents.utf8).write(to: file)
        return file
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: path).path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("Политика путей")
struct PathPolicyTests {
    private let policy = PathPolicy(home: URL(filePath: "/Users/test", directoryHint: .isDirectory))

    private func allows(_ path: String, _ access: PathPolicy.Access) -> Bool {
        policy.allows(URL(filePath: path), for: access)
    }

    @Test("Читать можно домашнюю папку, кроме Библиотеки и скрытых папок")
    func read() {
        #expect(allows("/Users/test/Documents/report.pdf", .read))
        #expect(allows("/Users/test/notes.txt", .read))
        #expect(!allows("/Users/test/Library/Keychains/login.keychain-db", .read))
        #expect(!allows("/Users/test/library/Mail/x", .read))
        #expect(!allows("/Users/test/.ssh/id_ed25519", .read))
        #expect(!allows("/Users/test/Documents/.git/config", .read))
        #expect(!allows("/etc/hosts", .read))
        #expect(!allows("/Users/other/report.pdf", .read))
        #expect(!allows("/Users/test/../other/report.pdf", .read))
    }

    @Test("Стандартные папки и содержимое пакетов менять нельзя")
    func modify() {
        #expect(allows("/Users/test/Documents/report.pdf", .modify))
        #expect(allows("/Users/test/Documents/Work", .modify))
        #expect(!allows("/Users/test/Documents", .modify))
        #expect(!allows("/Users/test/Downloads", .modify))
        #expect(!allows("/Users/test", .modify))
        #expect(!allows("/Users/test/Applications/Foo.app/Contents/Info.plist", .modify))
        #expect(!allows("/Users/test/Pictures/Photos Library.photoslibrary/database", .modify))
        #expect(allows("/Users/test/Documents/Report.pages", .modify))
    }

    @Test("Класть файлы можно в стандартные папки, но не в Библиотеку и не внутрь пакета")
    func destination() {
        #expect(allows("/Users/test/Documents", .destination))
        #expect(allows("/Users/test", .destination))
        #expect(!allows("/Users/test/Library", .destination))
        #expect(!allows("/Users/test/Pictures/Photos Library.photoslibrary", .destination))
    }

    @Test("Ссылка на системную папку не выводит за пределы домашней")
    func symlinks() throws {
        let home = try SandboxHome()
        defer { home.remove() }
        let link = home.url.appending(path: "Desktop/etc-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/etc"))
        let sandboxPolicy = PathPolicy(home: home.url)
        #expect(!sandboxPolicy.allows(link.appending(path: "hosts"), for: .read))
        let file = try home.file("Desktop/note.txt")
        #expect(sandboxPolicy.allows(file, for: .modify))
    }

    @Test("Скрипты, установщики и приложения не открываются")
    func unsafeToOpen() {
        let unsafe = ["install.command", "run.sh", "Setup.pkg", "Tool.app", "auto.workflow", "link.webloc"]
        for name in unsafe {
            #expect(PathPolicy.isUnsafeToOpen(URL(filePath: "/Users/test/\(name)"), isDirectory: false, isExecutable: false))
        }
        #expect(!PathPolicy.isUnsafeToOpen(URL(filePath: "/Users/test/report.pdf"), isDirectory: false, isExecutable: false))
        #expect(PathPolicy.isUnsafeToOpen(URL(filePath: "/Users/test/binary"), isDirectory: false, isExecutable: true))
        #expect(!PathPolicy.isUnsafeToOpen(URL(filePath: "/Users/test/Folder"), isDirectory: true, isExecutable: true))
    }
}

@Suite("Поиск файлов")
struct FileSearchTests {
    private func finder(_ home: SandboxHome) -> FileFinder {
        FileFinder(policy: PathPolicy(home: home.url), useSpotlight: false)
    }

    @Test("Последний скачанный PDF; Библиотека и скрытые папки не ищутся")
    func latestDownloadedPDF() throws {
        let home = try SandboxHome()
        defer { home.remove() }
        try home.file("Downloads/old.pdf")
        try home.file("Downloads/photo.png")
        try home.file("Library/secret.pdf")
        try home.file(".ssh/key.pdf")
        Thread.sleep(forTimeInterval: 0.05)
        try home.file("Downloads/invoice.pdf")

        let result = finder(home).search(FileSearchRequest(kind: .pdf, location: .downloads, latest: true))
        #expect(result.total == 2)
        #expect(result.files.first?.url.lastPathComponent == "invoice.pdf")

        let everywhere = finder(home).search(FileSearchRequest(kind: .pdf))
        let names = Set(everywhere.files.map(\.url.lastPathComponent))
        #expect(names == ["old.pdf", "invoice.pdf"])
    }

    @Test("По названию: падежи и «ё»; папки; скриншоты; период")
    func byNameKindAndPeriod() throws {
        let home = try SandboxHome()
        defer { home.remove() }
        try home.file("Documents/Отчёт за март.docx")
        try home.file("Desktop/Снимок экрана 2026-11-10 в 10.00.00.png")
        try home.file("Desktop/cat.png")

        let search = finder(home)
        #expect(search.search(FileSearchRequest(name: "отчета")).files.first?.url.lastPathComponent == "Отчёт за март.docx")
        let folder = search.search(FileSearchRequest(name: "work", kind: .folder))
        #expect(folder.files.first?.url.lastPathComponent == "Work")
        #expect(folder.files.first?.isDirectory == true)
        let screenshots = search.search(FileSearchRequest(kind: .screenshot, location: .desktop))
        #expect(screenshots.files.map(\.url.lastPathComponent) == ["Снимок экрана 2026-11-10 в 10.00.00.png"])
        #expect(search.search(FileSearchRequest(kind: .image, period: .today)).total == 2)
        #expect(search.search(FileSearchRequest(kind: .image, period: .yesterday)).total == 0)
    }

    @Test("Лимит результатов и общее число")
    func limit() throws {
        let home = try SandboxHome()
        defer { home.remove() }
        for index in 1...5 { try home.file("Downloads/file\(index).txt") }
        let result = finder(home).search(FileSearchRequest(location: .downloads, limit: 3))
        #expect(result.files.count == 3)
        #expect(result.total == 5)
    }

    @Test("Запрос Spotlight: только буквы и цифры из слов пользователя")
    func spotlightQuery() {
        let query = FileFinder.spotlightQuery(for: FileSearchRequest(name: "отчёт", kind: .pdf))
        #expect(query?.contains("kMDItemFSName == \"*отче*\"cd") == true)
        #expect(query?.contains("kMDItemFSName == \"*.pdf\"c") == true)
        // Кавычки и операторы из «названия» в запрос не попадают.
        #expect(FileFinder.spotlightQuery(for: FileSearchRequest(name: "\" || true || \"")) == "(kMDItemFSName == \"*true*\"cd)")
        #expect(FileFinder.spotlightQuery(for: FileSearchRequest(location: .downloads, latest: true)) == nil)
    }
}

/// Записывает, что открыто и показано в Finder (вместо настоящего NSWorkspace).
@MainActor
private final class WorkspaceRecorder {
    var opened: [URL] = []
    var revealed: [[URL]] = []
}

@MainActor
@Suite("Действия с файлами и отмена")
struct FileActionToolsTests {
    private let english = Locale(identifier: "en_US")

    private func setUp() throws -> (SandboxHome, FileToolkit, ToolRegistry, ArgumentValidator, WorkspaceRecorder) {
        let home = try SandboxHome()
        let recorder = WorkspaceRecorder()
        let trash = home.url.appending(path: ".Trash")
        let kit = FileToolkit(
            policy: PathPolicy(home: home.url),
            useSpotlight: false,
            trasher: { url in
                let destination = trash.appending(path: url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            },
            opener: { url in
                recorder.opened.append(url)
                return true
            },
            revealer: { urls in recorder.revealed.append(urls) }
        )
        var registry = ToolRegistry()
        for tool in kit.tools { try registry.register(tool) }
        return (home, kit, registry, ArgumentValidator(homeDirectory: home.url.path), recorder)
    }

    private func call(
        _ registry: ToolRegistry,
        _ validator: ArgumentValidator,
        _ name: ToolName,
        _ arguments: [String: ArgumentValue] = [:]
    ) throws -> PreparedToolCall {
        try registry.prepare(ToolCall(toolName: name.rawValue, arguments: arguments), validator: validator)
    }

    private func context(_ locale: Locale = Locale(identifier: "ru_RU")) -> ToolContext {
        ToolContext(source: .typedText, locale: locale)
    }

    @Test("Найти: ответ с именем и путями для «открой его»")
    func find() async throws {
        let (home, _, registry, validator, _) = try setUp()
        defer { home.remove() }
        try home.file("Downloads/invoice.pdf")
        let prepared = try call(registry, validator, StandardTools.findFiles, ["kind": .string("pdf"), "location": .string("downloads")])
        let outcome = try await prepared.tool.run(prepared.arguments, context: context(english))
        #expect(outcome.message == "I found “invoice.pdf” in “Downloads”.")
        #expect(outcome.files?.count == 1)
        #expect(outcome.untrustedContent != nil)

        let missing = try call(registry, validator, StandardTools.findFiles, ["name": .string("несуществующий")])
        await #expect(throws: ToolFailure.notFound(target: "несуществующий")) {
            _ = try await missing.tool.run(missing.arguments, context: self.context())
        }
    }

    @Test("Переместить: точное описание, без перезаписи, отмена возвращает файл")
    func moveAndUndo() async throws {
        let (home, kit, registry, validator, _) = try setUp()
        defer { home.remove() }
        let source = try home.file("Downloads/invoice.pdf")
        let move = try call(registry, validator, StandardTools.moveFiles, [
            "paths": .list([.string(source.path)]),
            "destination": .string(home.url.appending(path: "Documents").path),
        ])
        let summary = try await move.tool.describe(move.arguments, context: context(english))
        #expect(summary == "move “invoice.pdf” from “Downloads” to “Documents”")
        #expect(!home.exists("Documents/invoice.pdf"))

        let outcome = try await move.tool.run(move.arguments, context: context(english))
        #expect(outcome.message == "“invoice.pdf” to “Documents”")
        #expect(home.exists("Documents/invoice.pdf"))
        #expect(!home.exists("Downloads/invoice.pdf"))
        #expect(kit.journal.count == 1)

        let undo = try call(registry, validator, StandardTools.undo)
        #expect(try await undo.tool.describe(undo.arguments, context: context(english)) == "move “invoice.pdf” back to “Downloads”")
        _ = try await undo.tool.run(undo.arguments, context: context(english))
        #expect(home.exists("Downloads/invoice.pdf"))
        #expect(kit.journal.count == 0)
        await #expect(throws: ToolFailure.nothingToUndo) {
            _ = try await undo.tool.describe(undo.arguments, context: self.context())
        }
    }

    @Test("Если в папке уже есть файл с таким именем — не делается ничего")
    func noOverwrite() async throws {
        let (home, _, registry, validator, _) = try setUp()
        defer { home.remove() }
        let first = try home.file("Downloads/a.txt", contents: "new")
        let second = try home.file("Downloads/b.txt")
        try home.file("Documents/b.txt", contents: "old")
        let move = try call(registry, validator, StandardTools.moveFiles, [
            "paths": .list([.string(first.path), .string(second.path)]),
            "destination": .string(home.url.appending(path: "Documents").path),
        ])
        await #expect(throws: ToolFailure.alreadyExists(target: "b.txt")) {
            _ = try await move.tool.run(move.arguments, context: self.context())
        }
        #expect(home.exists("Downloads/a.txt"))
        #expect(try String(contentsOf: home.url.appending(path: "Documents/b.txt"), encoding: .utf8) == "old")
    }

    @Test("Стандартные папки, Библиотека и скрытые файлы защищены")
    func protectedTargets() async throws {
        let (home, _, registry, validator, _) = try setUp()
        defer { home.remove() }
        let secret = try home.file("Library/secret.pdf")
        let documents = home.url.appending(path: "Documents")
        let trashDocuments = try call(registry, validator, StandardTools.trashFiles, ["paths": .list([.string(documents.path)])])
        await #expect(throws: ToolFailure.self) {
            _ = try await trashDocuments.tool.describe(trashDocuments.arguments, context: self.context())
        }
        let moveSecret = try call(registry, validator, StandardTools.moveFiles, [
            "paths": .list([.string(secret.path)]),
            "destination": .string(documents.path),
        ])
        await #expect(throws: ToolFailure.protectedTarget(target: "secret.pdf")) {
            _ = try await moveSecret.tool.describe(moveSecret.arguments, context: self.context())
        }
        #expect(home.exists("Documents"))
        #expect(home.exists("Library/secret.pdf"))
    }

    @Test("Переименовать: расширение сохраняется; отмена возвращает имя")
    func renameAndUndo() async throws {
        let (home, _, registry, validator, _) = try setUp()
        defer { home.remove() }
        let file = try home.file("Documents/draft.pdf")
        // «/» и «:» в имени macOS не допускает, точка в начале скрыла бы файл.
        for badName in ["a/b", "a:b", ".hidden"] {
            let bad = try call(registry, validator, StandardTools.renameFile, ["path": .string(file.path), "newName": .string(badName)])
            await #expect(throws: ToolFailure.self) {
                _ = try await bad.tool.run(bad.arguments, context: self.context())
            }
        }
        #expect(home.exists("Documents/draft.pdf"))

        let rename = try call(registry, validator, StandardTools.renameFile, ["path": .string(file.path), "newName": .string("Итоги марта")])
        #expect(try await rename.tool.describe(rename.arguments, context: context()) == "переименовать «draft.pdf» в «Итоги марта.pdf»")
        let outcome = try await rename.tool.run(rename.arguments, context: context())
        #expect(outcome.message == "«Итоги марта.pdf»")
        #expect(home.exists("Documents/Итоги марта.pdf"))

        let undo = try call(registry, validator, StandardTools.undo)
        _ = try await undo.tool.run(undo.arguments, context: context())
        #expect(home.exists("Documents/draft.pdf"))
        #expect(!home.exists("Documents/Итоги марта.pdf"))
    }

    @Test("В Корзину — категория 3; «отмени» возвращает файл из Корзины")
    func trashAndUndo() async throws {
        let (home, _, registry, validator, _) = try setUp()
        defer { home.remove() }
        let file = try home.file("Desktop/old.txt")
        let trash = try call(registry, validator, StandardTools.trashFiles, ["paths": .list([.string(file.path)])])
        #expect(trash.descriptor.risk == .dangerous)
        #expect(try await trash.tool.describe(trash.arguments, context: context()) == "переместить в Корзину «old.txt»")
        let outcome = try await trash.tool.run(trash.arguments, context: context())
        #expect(outcome.files == [])
        #expect(!home.exists("Desktop/old.txt"))
        #expect(home.exists(".Trash/old.txt"))

        let undo = try call(registry, validator, StandardTools.undo)
        #expect(try await undo.tool.describe(undo.arguments, context: context()).hasPrefix("вернуть «old.txt» из Корзины в «"))
        _ = try await undo.tool.run(undo.arguments, context: context())
        #expect(home.exists("Desktop/old.txt"))
    }

    @Test("Открыть и показать в Finder; скрипты не открываются")
    func openAndReveal() async throws {
        let (home, _, registry, validator, recorder) = try setUp()
        defer { home.remove() }
        let report = try home.file("Documents/report.pdf")
        let script = try home.file("Downloads/install.command")

        let open = try call(registry, validator, StandardTools.openFile, ["path": .string(report.path)])
        let opened = try await open.tool.run(open.arguments, context: context())
        #expect(opened.message == "«report.pdf»")
        #expect(opened.files == nil)
        #expect(recorder.opened.map(\.lastPathComponent) == ["report.pdf"])

        let openScript = try call(registry, validator, StandardTools.openFile, ["path": .string(script.path)])
        await #expect(throws: ToolFailure.unsafeToOpen(target: "install.command")) {
            _ = try await openScript.tool.run(openScript.arguments, context: self.context())
        }
        #expect(recorder.opened.count == 1)

        let reveal = try call(registry, validator, StandardTools.revealFiles, ["paths": .list([.string(report.path)])])
        _ = try await reveal.tool.run(reveal.arguments, context: context())
        #expect(recorder.revealed.count == 1)
    }

    @Test("Журнал отмены хранит только последние действия")
    func journalCapacity() {
        let journal = UndoJournal()
        for index in 0..<(UndoJournal.capacity + 5) {
            let url = URL(filePath: "/tmp/\(index)")
            journal.record(UndoEntry(id: UUID(), kind: .move, moves: [FileMove(from: url, to: url)]))
        }
        #expect(journal.count == UndoJournal.capacity)
        journal.record(UndoEntry(id: UUID(), kind: .move, moves: []))
        #expect(journal.count == UndoJournal.capacity)
    }
}
