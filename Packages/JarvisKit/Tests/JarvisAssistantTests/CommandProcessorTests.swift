import Foundation
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
        let mail = await processor.handle(utterance("открой почту"), source: .typedText, context: russian)
        #expect(mail.reply == "Работать с почтой я научусь в следующей версии.")
        let entries = try await audit.recentEntries()
        #expect(entries.isEmpty)
    }

    @Test("Действие, требующее подтверждения, не выполняется (подтверждения — в Phase 3)")
    func confirmationRequiredIsDenied() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let audit = AuditLog(directory: directory.url)
        var registry = ToolRegistry()
        try registry.register(DangerousTool())
        let processor = try makeProcessor(registry: registry, audit: audit)

        let outcome = await processor.handle(utterance("который час"), source: .voiceWakeWord, context: russian)

        #expect(outcome.reply.contains("подтверждения"))
        #expect(outcome.executedActions.isEmpty)
        let entries = try await audit.recentEntries()
        #expect(entries.first?.outcome == .deniedByPolicy)
        #expect(entries.first?.confirmationRequired == true)
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
