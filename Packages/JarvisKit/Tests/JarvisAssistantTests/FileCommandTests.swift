import Foundation
import Synchronization
import Testing
import JarvisAI
import JarvisCore
import JarvisTools
@testable import JarvisAssistant

/// Поддельный поиск файлов: возвращает заданные пути и запоминает аргументы.
private final class FakeFindTool: Tool {
    let descriptor = ToolDescriptor(
        name: StandardTools.findFiles,
        summary: "Найти файлы",
        parameters: [
            ParameterSpec(name: "name", summary: "Название", type: .text(maxLength: 100), isRequired: false),
            ParameterSpec(name: "kind", summary: "Тип", type: .choice(FileKind.allCases.map(\.rawValue)), isRequired: false),
            ParameterSpec(name: "location", summary: "Папка", type: .choice(FileLocation.allCases.map(\.rawValue)), isRequired: false),
            ParameterSpec(name: "period", summary: "Период", type: .choice(FilePeriod.allCases.map(\.rawValue)), isRequired: false),
            ParameterSpec(name: "latest", summary: "Новые", type: .boolean, isRequired: false),
            ParameterSpec(name: "limit", summary: "Сколько", type: .integer(1...101), isRequired: false),
        ],
        risk: .safe,
        requiredPermissions: [.filesAndFolders],
        effect: .readOnly,
        producesUntrustedContent: true
    )
    private let results: [String]
    private let calls = Mutex<[[String: ArgumentValue]]>([])

    init(_ results: [String]) {
        self.results = results
    }

    var recorded: [[String: ArgumentValue]] { calls.withLock { $0 } }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        calls.withLock { $0.append(arguments.values) }
        guard !results.isEmpty else { throw ToolFailure.notFound(target: arguments.text("name") ?? "") }
        let limit = arguments.integer("limit") ?? 20
        return ToolOutcome(message: "Нашёл: \(results.count).", files: Array(results.prefix(limit)))
    }
}

/// Поддельное действие с файлами: запоминает вызовы, описывает себя по первому файлу.
private final class FakeFileTool: Tool {
    let descriptor: ToolDescriptor
    private let calls = Mutex<[[String: ArgumentValue]]>([])
    private let files: [String]?

    init(_ name: ToolName, parameters: [ParameterSpec], risk: RiskLevel, files: [String]? = nil) {
        descriptor = ToolDescriptor(name: name, summary: "Тест", parameters: parameters, risk: risk, requiredPermissions: [.filesAndFolders], effect: .local)
        self.files = files
    }

    var recorded: [[String: ArgumentValue]] { calls.withLock { $0 } }

    func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String {
        "действие «\(Self.firstName(arguments))»"
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        calls.withLock { $0.append(arguments.values) }
        return ToolOutcome(message: "«\(Self.firstName(arguments))»", files: files)
    }

    private static func firstName(_ arguments: ValidatedArguments) -> String {
        if let path = arguments.text("path") { return URL(filePath: path).lastPathComponent }
        if case .string(let path)? = arguments.list("paths")?.first { return URL(filePath: path).lastPathComponent }
        return "последнее действие"
    }
}

@MainActor
private final class FakePermissions: PermissionChecking {
    var denied: Set<PermissionKind> = []

    func status(for kind: PermissionKind) -> PermissionStatus {
        denied.contains(kind) ? .denied : .unknown
    }
}

private let pathParameter = ParameterSpec(name: "path", summary: "Путь", type: .filePath)
private let pathsParameter = ParameterSpec(name: "paths", summary: "Пути", type: .list(.filePath, maxCount: 100))

/// Набор поддельных файловых инструментов и процессор с домашней папкой /Users/test.
@MainActor
private struct FileHarness {
    let find: FakeFindTool
    let open = FakeFileTool(StandardTools.openFile, parameters: [pathParameter], risk: .safe)
    let reveal = FakeFileTool(StandardTools.revealFiles, parameters: [pathsParameter], risk: .safe)
    let move = FakeFileTool(
        StandardTools.moveFiles,
        parameters: [pathsParameter, ParameterSpec(name: "destination", summary: "Куда", type: .filePath)],
        risk: .consequential,
        files: ["/Users/test/Documents/a.pdf"]
    )
    let rename = FakeFileTool(
        StandardTools.renameFile,
        parameters: [pathParameter, ParameterSpec(name: "newName", summary: "Имя", type: .text(maxLength: 200))],
        risk: .consequential
    )
    let trash = FakeFileTool(StandardTools.trashFiles, parameters: [pathsParameter], risk: .dangerous, files: [])
    let undo = FakeFileTool(StandardTools.undo, parameters: [], risk: .consequential)
    let permissions = FakePermissions()
    let processor: CommandProcessor
    let directory: TemporaryDirectory

    init(results: [String]) throws {
        find = FakeFindTool(results)
        directory = try TemporaryDirectory()
        var registry = ToolRegistry()
        let tools: [any Tool] = [find, open, reveal, move, rename, trash, undo]
        for tool in tools {
            try registry.register(tool)
        }
        processor = CommandProcessor(
            registry: registry,
            auditLog: AuditLog(directory: directory.url),
            validator: ArgumentValidator(homeDirectory: "/Users/test"),
            permissions: permissions,
            random: SeededRandomNumberGenerator(seed: 1)
        )
    }

    private let russian = CommandContext(locale: Locale(identifier: "ru_RU"), personality: Personality(humor: 0, verbosity: 0.5, formality: 0))

    func say(_ text: String) async -> CommandOutcome {
        await processor.handle(Utterance(text: text, locale: Locale(identifier: "ru_RU")), source: .voiceWakeWord, context: russian)
    }

    func confirm(_ pending: PendingAction) async -> CommandOutcome {
        await processor.confirm(pending, context: russian)
    }
}

private let downloads = ["/Users/test/Downloads/a.pdf", "/Users/test/Downloads/b.pdf", "/Users/test/Downloads/c.pdf"]

@MainActor
@Suite("Файловые команды")
struct FileCommandTests {
    @Test("«Найди последний скачанный PDF», потом «открой его» и «открой второй»")
    func findThenOpen() async throws {
        let h = try FileHarness(results: downloads)
        defer { h.directory.remove() }

        let found = await h.say("найди последний скачанный pdf")
        #expect(found.reply == "Нашёл: 3.")
        #expect(found.executedActions == [StandardTools.findFiles])
        #expect(h.find.recorded == [[
            "kind": .string("pdf"), "location": .string("downloads"), "latest": .boolean(true), "limit": .integer(20),
        ]])

        let first = await h.say("открой его")
        #expect(first.reply == "Открываю «a.pdf».")
        let second = await h.say("открой второй")
        #expect(second.reply == "Открываю «b.pdf».")
        #expect(h.open.recorded == [["path": .string(downloads[0])], ["path": .string(downloads[1])]])

        let fifth = await h.say("открой пятый")
        #expect(fifth.reply == "В списке только 3 файла.")
        #expect(h.open.recorded.count == 2)
    }

    @Test("«Открой его» без поиска — подсказка, а не случайный файл")
    func nothingRemembered() async throws {
        let h = try FileHarness(results: downloads)
        defer { h.directory.remove() }
        let outcome = await h.say("открой его")
        #expect(outcome.reply.hasPrefix("Сначала найди файл"))
        #expect(h.open.recorded.isEmpty)
        #expect(h.find.recorded.isEmpty)
    }

    @Test("Несколько подходящих файлов — «какой из них?», ответ «второй» открывает второй")
    func whichOne() async throws {
        let h = try FileHarness(results: downloads)
        defer { h.directory.remove() }
        let asked = await h.say("открой файл отчёт")
        #expect(asked.reply == "Нашёл 3 файла: «a.pdf», «b.pdf» и «c.pdf». Какой из них? Скажи «первый», «второй»…")
        #expect(h.open.recorded.isEmpty)

        let chosen = await h.say("второй")
        #expect(chosen.reply == "Открываю «b.pdf».")
        #expect(h.open.recorded == [["path": .string(downloads[1])]])
    }

    @Test("«Последний» из нескольких — сразу первый, без вопроса")
    func latestNeedsNoQuestion() async throws {
        let h = try FileHarness(results: downloads)
        defer { h.directory.remove() }
        let outcome = await h.say("открой последний скачанный pdf")
        #expect(outcome.reply == "Открываю «a.pdf».")
    }

    @Test("Стандартная папка открывается по пути в домашней папке")
    func openFolder() async throws {
        let h = try FileHarness(results: [])
        defer { h.directory.remove() }
        _ = await h.say("открой загрузки")
        #expect(h.open.recorded == [["path": .string("/Users/test/Downloads")]])
    }

    @Test("Переместить: вопрос с точным файлом, после «да» — ровно этот файл и папка")
    func moveAfterFind() async throws {
        let h = try FileHarness(results: downloads)
        defer { h.directory.remove() }
        _ = await h.say("найди последний скачанный pdf")

        let asked = await h.say("перемести его в документы")
        let pending = try #require(asked.pendingAction)
        #expect(asked.reply == "Точно действие «a.pdf»?")
        #expect(pending.items == ["a.pdf"])
        #expect(pending.allowsVoiceConfirmation)
        #expect(h.move.recorded.isEmpty)

        let done = await h.confirm(pending)
        #expect(done.executedActions == [StandardTools.moveFiles])
        #expect(h.move.recorded == [[
            "paths": .list([.string(downloads[0])]),
            "destination": .string("/Users/test/Documents"),
        ]])
        // После перемещения «его» — это файл на новом месте.
        _ = await h.say("открой его")
        #expect(h.open.recorded == [["path": .string("/Users/test/Documents/a.pdf")]])
    }

    @Test("Больше 10 файлов — категория 3: только кнопкой, в окне — все имена")
    func bulkMoveIsDangerous() async throws {
        let many = (1...12).map { "/Users/test/Downloads/file\($0).pdf" }
        let h = try FileHarness(results: many)
        defer { h.directory.remove() }
        let asked = await h.say("перемести все pdf из загрузок в документы")
        let pending = try #require(asked.pendingAction)
        #expect(pending.isDangerous)
        #expect(!pending.allowsVoiceConfirmation)
        #expect(pending.items.count == 12)
        #expect(h.find.recorded.first?["limit"] == .integer(StandardTools.maxFilesPerAction + 1))
    }

    @Test("Слишком много файлов для одного действия — уточнить")
    func tooMany() async throws {
        let many = (1...150).map { "/Users/test/Downloads/file\($0).pdf" }
        let h = try FileHarness(results: many)
        defer { h.directory.remove() }
        let outcome = await h.say("удали все pdf из загрузок")
        #expect(outcome.reply == "Слишком много файлов — больше 100. Уточни, какие.")
        #expect(outcome.pendingAction == nil)
        #expect(h.trash.recorded.isEmpty)
    }

    @Test("Удалить — категория 3, подтверждение только кнопкой")
    func trashNeedsButton() async throws {
        let h = try FileHarness(results: downloads)
        defer { h.directory.remove() }
        _ = await h.say("найди последний скачанный pdf")
        let asked = await h.say("удали его")
        let pending = try #require(asked.pendingAction)
        #expect(!pending.allowsVoiceConfirmation)
        #expect(asked.reply == "Подтверди в окне JARVIS: действие «a.pdf».")
        _ = await h.confirm(pending)
        #expect(h.trash.recorded == [["paths": .list([.string(downloads[0])])]])
        // Удалённые файлы забываются.
        #expect((await h.say("открой его")).reply.hasPrefix("Сначала найди файл"))
    }

    @Test("Не хватает подробностей — JARVIS спрашивает, ничего не ищет")
    func missingDetails() async throws {
        let h = try FileHarness(results: downloads)
        defer { h.directory.remove() }
        _ = await h.say("найди последний скачанный pdf")
        #expect((await h.say("перемести файл отчёт")).reply == "Куда? Скажи, например, «перемести его в Документы».")
        #expect((await h.say("переименуй его")).reply == "Как назвать? Скажи, например, «переименуй его в Отчёт за март».")
        #expect((await h.say("найди файл")).reply.hasPrefix("Какой файл?"))
        #expect((await h.say("открой папку")).reply.hasPrefix("Какой файл?"))
        #expect(h.find.recorded.count == 1)
    }

    @Test("Переименовать: новое имя передаётся как сказано")
    func renameArguments() async throws {
        let h = try FileHarness(results: downloads)
        defer { h.directory.remove() }
        _ = await h.say("найди последний скачанный pdf")
        let pending = try #require(await h.say("переименуй его в Итоги марта").pendingAction)
        _ = await h.confirm(pending)
        #expect(h.rename.recorded == [["path": .string(downloads[0]), "newName": .string("Итоги марта")]])
    }

    @Test("«Отмени» — через инструмент отмены, с подтверждением")
    func undo() async throws {
        let h = try FileHarness(results: [])
        defer { h.directory.remove() }
        let asked = await h.say("отмени")
        let pending = try #require(asked.pendingAction)
        #expect(asked.reply == "Точно действие «последнее действие»?")
        _ = await h.confirm(pending)
        #expect(h.undo.recorded.count == 1)
    }

    @Test("Файл не найден — понятный ответ")
    func notFound() async throws {
        let h = try FileHarness(results: [])
        defer { h.directory.remove() }
        #expect((await h.say("открой файл диплом")).reply == "Не нашёл файлов «диплом».")
        #expect((await h.say("перемести его в папку работа")).reply.hasPrefix("Сначала найди файл"))
    }

    @Test("Нет доступа к файлам — не ищем, а говорим, где разрешить")
    func permissionDenied() async throws {
        let h = try FileHarness(results: downloads)
        defer { h.directory.remove() }
        h.permissions.denied = [.filesAndFolders]
        let outcome = await h.say("найди последний скачанный pdf")
        #expect(outcome.reply.contains("Файлы и папки"))
        #expect(h.find.recorded.isEmpty)
        #expect((await h.say("открой загрузки")).reply.contains("Файлы и папки"))
        #expect(h.open.recorded.isEmpty)
    }

    @Test("После выключения ассистента найденные файлы забываются")
    func forget() async throws {
        let h = try FileHarness(results: downloads)
        defer { h.directory.remove() }
        _ = await h.say("найди последний скачанный pdf")
        h.processor.forgetContext()
        #expect((await h.say("открой его")).reply.hasPrefix("Сначала найди файл"))
    }

    @Test("Через 10 минут «его» забывается")
    func recentFilesExpire() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let clock = ManualDate()
        var registry = ToolRegistry()
        let open = FakeFileTool(StandardTools.openFile, parameters: [pathParameter], risk: .safe)
        try registry.register(FakeFindTool(downloads))
        try registry.register(open)
        let processor = CommandProcessor(
            registry: registry,
            auditLog: AuditLog(directory: directory.url),
            random: SeededRandomNumberGenerator(seed: 1),
            now: { clock.now }
        )
        let context = CommandContext(locale: Locale(identifier: "ru_RU"))
        func say(_ text: String) async -> CommandOutcome {
            await processor.handle(Utterance(text: text, locale: Locale(identifier: "ru_RU")), source: .typedText, context: context)
        }
        _ = await say("найди последний скачанный pdf")
        clock.now += CommandProcessor.recentFilesLifetime + 1
        #expect((await say("открой его")).reply.hasPrefix("Сначала найди файл"))
        #expect(open.recorded.isEmpty)
    }
}

/// Часы для проверки «забывания» (используются только из одного теста).
private final class ManualDate: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}
