import Foundation
import Synchronization
import Testing
import JarvisAI
import JarvisCore
import JarvisTools
@testable import JarvisAssistant

private struct FailingTool: Tool {
    let descriptor = ToolDescriptor(name: "info.time", summary: "Ломается", risk: .safe, effect: .readOnly)

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        throw CocoaError(.featureUnsupported)
    }
}

private struct DangerousTool: Tool {
    let descriptor = ToolDescriptor(name: "info.time", summary: "Опасный", risk: .dangerous, effect: .local)

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        Issue.record("Опасный инструмент не должен выполняться без подтверждения")
        return ToolOutcome(message: "")
    }
}

/// Инструмент-подделка: запоминает вызовы, может «не найти» цель или сломаться.
private final class RecordingTool: Tool {
    let descriptor: ToolDescriptor
    private let calls = Mutex<[[String: ArgumentValue]]>([])
    private let message: String
    private let failure: ToolFailure?
    private let describeFailure: ToolFailure?

    init(
        _ name: ToolName,
        parameters: [ParameterSpec],
        risk: RiskLevel = .safe,
        message: String = "ok",
        failure: ToolFailure? = nil,
        describeFailure: ToolFailure? = nil
    ) {
        descriptor = ToolDescriptor(name: name, summary: "Тест", parameters: parameters, risk: risk, effect: .local)
        self.message = message
        self.failure = failure
        self.describeFailure = describeFailure
    }

    var recorded: [[String: ArgumentValue]] { calls.withLock { $0 } }

    func describe(_ arguments: ValidatedArguments, context: ToolContext) async throws -> String {
        if let describeFailure { throw describeFailure }
        return "закрыть «\(arguments.text("name") ?? "")»"
    }

    func run(_ arguments: ValidatedArguments, context: ToolContext) async throws -> ToolOutcome {
        calls.withLock { $0.append(arguments.values) }
        if let failure { throw failure }
        return ToolOutcome(message: message)
    }
}

private let nameParameter = [ParameterSpec(name: "name", summary: "Имя", type: .text(maxLength: 100))]

@MainActor
@Suite("Обработка команд")
struct CommandProcessorTests {
    private let russian = CommandContext(locale: Locale(identifier: "ru_RU"), personality: Personality(humor: 0, verbosity: 0.5, formality: 0))

    private func makeProcessor(registry: ToolRegistry? = nil, audit: AuditLog) throws -> CommandProcessor {
        let utc = TimeZone(identifier: "UTC") ?? .current
        let tools = try registry ?? BuiltInTools.makeRegistry(now: { fixedNoon }, timeZone: utc)
        return CommandProcessor(registry: tools, auditLog: audit, random: SeededRandomNumberGenerator(seed: 1))
    }

    private func utterance(_ text: String) -> Utterance {
        Utterance(text: text, locale: Locale(identifier: "ru_RU"))
    }

    @Test("«Который час» выполняет инструмент и пишет в журнал без текста команды")
    func timeCommand() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let audit = AuditLog(directory: directory.url)
        let processor = try makeProcessor(audit: audit)

        let outcome = await processor.handle(utterance("который час"), source: .voicePushToTalk, context: russian)

        #expect(outcome.intent == .currentTime)
        #expect(outcome.reply == "Сейчас 12:00.")
        #expect(outcome.executedActions == [BuiltInTools.currentTime])
        let entries = try await audit.recentEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.action == BuiltInTools.currentTime)
        #expect(entries.first?.source == .voicePushToTalk)
        #expect(entries.first?.outcome == .succeeded)
        #expect(entries.first?.detail == nil)
    }

    @Test("Дата на русском")
    func dateCommand() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let processor = try makeProcessor(audit: AuditLog(directory: directory.url))

        let outcome = await processor.handle(utterance("какое сегодня число"), source: .typedText, context: russian)
        #expect(outcome.reply.hasPrefix("Сегодня"))
        #expect(outcome.reply.contains("пятница"))
        #expect(outcome.reply.contains("6 ноября"))
    }

    @Test("Команды управления ассистентом возвращают директиву")
    func directives() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let processor = try makeProcessor(audit: AuditLog(directory: directory.url))

        #expect(await processor.handle(utterance("выключись"), source: .voiceWakeWord, context: russian).directive == .disableAssistant)
        #expect(await processor.handle(utterance("не слушай"), source: .voiceWakeWord, context: russian).directive == .pauseMicrophone)
        #expect(await processor.handle(utterance("включи приватный режим"), source: .typedText, context: russian).directive == .setPrivacyMode(true))
    }

    @Test("Разговорные и неизвестные команды не пишут в журнал")
    func smallTalkIsNotAudited() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let audit = AuditLog(directory: directory.url)
        let processor = try makeProcessor(audit: audit)

        let unknown = await processor.handle(utterance("расскажи анекдот"), source: .typedText, context: russian)
        #expect(unknown.intent == .unknown)
        #expect(!unknown.reply.isEmpty)
        let mail = await processor.handle(utterance("проверь почту"), source: .typedText, context: russian)
        #expect(mail.reply == "Работать с почтой я научусь в следующей версии.")
        let entries = try await audit.recentEntries()
        #expect(entries.isEmpty)
    }

    @Test("Закрытие приложения: сначала вопрос, выполнение — только после «да»")
    func confirmationThenRun() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let audit = AuditLog(directory: directory.url)
        let quit = RecordingTool(StandardTools.quitApp, parameters: nameParameter, risk: .consequential, message: "Safari")
        var registry = ToolRegistry()
        try registry.register(quit)
        let processor = try makeProcessor(registry: registry, audit: audit)

        let asked = await processor.handle(utterance("закрой сафари"), source: .voiceWakeWord, context: russian)
        let pending = try #require(asked.pendingAction)
        #expect(asked.reply == "Точно закрыть «сафари»?")
        #expect(pending.summary == "закрыть «сафари»")
        #expect(pending.allowsVoiceConfirmation)
        #expect(asked.executedActions.isEmpty)
        #expect(quit.recorded.isEmpty)
        #expect(try await audit.recentEntries().isEmpty)

        let done = await processor.confirm(pending, context: russian)
        #expect(done.reply == "Закрываю Safari.")
        #expect(done.executedActions == [StandardTools.quitApp])
        #expect(quit.recorded == [["name": .string("сафари")]])
        let entries = try await audit.recentEntries()
        #expect(entries.first?.outcome == .succeeded)
        #expect(entries.first?.confirmationRequired == true)
    }

    @Test("«Нет», молчание и непонятный ответ ничего не выполняют; в журнале — «отменено»")
    func declineAndTimeout() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let audit = AuditLog(directory: directory.url)
        let quit = RecordingTool(StandardTools.quitApp, parameters: nameParameter, risk: .consequential)
        var registry = ToolRegistry()
        try registry.register(quit)
        let processor = try makeProcessor(registry: registry, audit: audit)

        let first = try #require(await processor.handle(utterance("закрой сафари"), source: .voicePushToTalk, context: russian).pendingAction)
        #expect(await processor.decline(first, reason: .declined, context: russian).reply == "Хорошо, не делаю.")
        let second = try #require(await processor.handle(utterance("закрой сафари"), source: .voicePushToTalk, context: russian).pendingAction)
        #expect(await processor.decline(second, reason: .timedOut, context: russian).reply == "Не дождался ответа — ничего не делаю.")
        let third = try #require(await processor.handle(utterance("закрой сафари"), source: .voicePushToTalk, context: russian).pendingAction)
        #expect(await processor.decline(third, reason: .notUnderstood, context: russian).reply == "Не расслышал ответ — ничего не делаю.")

        #expect(quit.recorded.isEmpty)
        let entries = try await audit.recentEntries()
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.outcome == .cancelledByUser && $0.confirmationRequired })
    }

    @Test("Опасное действие (категория 3) подтверждается только кнопкой")
    func dangerousNeedsPhysicalConfirmation() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var registry = ToolRegistry()
        try registry.register(DangerousTool())
        let processor = try makeProcessor(registry: registry, audit: AuditLog(directory: directory.url))

        let outcome = await processor.handle(utterance("который час"), source: .voiceWakeWord, context: russian)
        let pending = try #require(outcome.pendingAction)
        #expect(!pending.allowsVoiceConfirmation)
        #expect(pending.isDangerous)
        #expect(outcome.reply.hasPrefix("Подтверди в окне JARVIS"))
    }

    @Test("Если подтверждение категории 2 выключено в настройках — выполняется сразу")
    func consequentialWithoutConfirmation() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let quit = RecordingTool(StandardTools.quitApp, parameters: nameParameter, risk: .consequential, message: "Safari")
        var registry = ToolRegistry()
        try registry.register(quit)
        let processor = try makeProcessor(registry: registry, audit: AuditLog(directory: directory.url))
        var context = russian
        context.confirmationPolicy = ConfirmationPolicy(confirmConsequentialActions: false)

        let outcome = await processor.handle(utterance("закрой сафари"), source: .typedText, context: context)
        #expect(outcome.pendingAction == nil)
        #expect(quit.recorded.count == 1)
    }

    @Test("Понятные причины: не запущено, защищено — ещё до вопроса")
    func failuresBeforeQuestion() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var registry = ToolRegistry()
        try registry.register(RecordingTool(
            StandardTools.quitApp,
            parameters: nameParameter,
            risk: .consequential,
            describeFailure: .notRunning(target: "Safari")
        ))
        let processor = try makeProcessor(registry: registry, audit: AuditLog(directory: directory.url))

        let outcome = await processor.handle(utterance("закрой сафари"), source: .voiceWakeWord, context: russian)
        #expect(outcome.pendingAction == nil)
        #expect(outcome.reply == "«Safari» и так не запущено.")
    }

    @Test("Приложения нет, но это известный сайт — открывается сайт")
    func appFallsBackToWebsite() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let apps = RecordingTool(StandardTools.openApp, parameters: nameParameter, failure: .notFound(target: "ютуб"))
        let web = RecordingTool(
            StandardTools.openWebsite,
            parameters: [ParameterSpec(name: "url", summary: "Адрес", type: .webURL)],
            message: "youtube.com"
        )
        var registry = ToolRegistry()
        try registry.register(apps)
        try registry.register(web)
        let processor = try makeProcessor(registry: registry, audit: AuditLog(directory: directory.url))

        let outcome = await processor.handle(utterance("открой ютуб"), source: .voiceWakeWord, context: russian)
        #expect(web.recorded == [["url": .string("https://www.youtube.com")]])
        #expect(outcome.reply == "Открываю youtube.com.")

        let unknown = await processor.handle(utterance("открой фотошоп"), source: .voiceWakeWord, context: russian)
        #expect(unknown.reply == "Не нашёл приложение «ютуб».")
    }

    @Test("Громкость и поиск: правильные аргументы инструментов")
    func volumeAndSearchArguments() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let change = RecordingTool(
            StandardTools.changeVolume,
            parameters: [ParameterSpec(name: "delta", summary: "Шаг", type: .integer(-100...100))],
            message: "60 %"
        )
        let search = RecordingTool(StandardTools.webSearch, parameters: [
            ParameterSpec(name: "query", summary: "Запрос", type: .text(maxLength: 200)),
            ParameterSpec(name: "engine", summary: "Система", type: .choice(StandardTools.searchEngines), isRequired: false),
        ])
        var registry = ToolRegistry()
        try registry.register(change)
        try registry.register(search)
        let processor = try makeProcessor(registry: registry, audit: AuditLog(directory: directory.url))
        var context = russian
        context.searchEngine = "yandex"

        let louder = await processor.handle(utterance("сделай погромче"), source: .voiceWakeWord, context: context)
        #expect(change.recorded == [["delta": .integer(CommandProcessor.volumeStep)]])
        #expect(louder.reply == "Громкость 60 %.")

        _ = await processor.handle(utterance("найди в интернете рецепт борща"), source: .voiceWakeWord, context: context)
        #expect(search.recorded == [["query": .string("рецепт борща"), "engine": .string("yandex")]])
    }

    @Test("Ошибка инструмента — понятный ответ и запись «ошибка» в журнале")
    func toolFailure() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let audit = AuditLog(directory: directory.url)
        var registry = ToolRegistry()
        try registry.register(FailingTool())
        let processor = try makeProcessor(registry: registry, audit: audit)

        let outcome = await processor.handle(utterance("который час"), source: .typedText, context: russian)

        #expect(outcome.reply == "Что-то пошло не так. Попробуй ещё раз.")
        let entries = try await audit.recentEntries()
        #expect(entries.first?.outcome == .failed)
    }

    @Test("Время по-английски")
    func englishTime() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let processor = try makeProcessor(audit: AuditLog(directory: directory.url))
        let english = CommandContext(locale: Locale(identifier: "en_US"), personality: Personality(humor: 0, verbosity: 0.5, formality: 0))

        let outcome = await processor.handle(Utterance(text: "what time is it", locale: Locale(identifier: "en_US")), source: .typedText, context: english)
        #expect(outcome.reply.hasPrefix("It's 12:00"))
    }
}
