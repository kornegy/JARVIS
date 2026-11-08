import Foundation
import JarvisAI
import JarvisCore
import JarvisTools

/// Изменение состояния ассистента, которое просит команда.
public enum AssistantDirective: Sendable, Equatable {
    case disableAssistant
    case pauseMicrophone
    case setPrivacyMode(Bool)
}

/// Действие, которое ждёт подтверждения пользователя («Точно закрыть «Safari»?»).
///
/// Хранит уже проверенный вызов инструмента: после «да» выполняется **ровно то**, что
/// было показано, без повторного разбора команды.
public struct PendingAction: Sendable, Equatable {
    public let id: UUID
    /// Что именно будет сделано — для окна подтверждения («закрыть «Safari»»).
    public let summary: String
    /// `false` — подтвердить можно только кнопкой или клавишей (категория 3).
    public let allowsVoiceConfirmation: Bool
    public let isDangerous: Bool
    let call: PreparedToolCall
    let intent: Intent
    let source: CommandSource

    public static func == (lhs: PendingAction, rhs: PendingAction) -> Bool { lhs.id == rhs.id }
}

/// Почему действие не выполнено после вопроса.
public enum DeclineReason: Sendable, Equatable {
    /// Пользователь ответил «нет» или нажал «Нет»/Esc.
    case declined
    /// 30 секунд без ответа.
    case timedOut
    /// Ответ не распознан — безопасный вариант: ничего не делать.
    case notUnderstood
    /// Ассистент выключили, пока он ждал ответа.
    case cancelled
}

/// Результат обработки команды.
public struct CommandOutcome: Sendable, Equatable {
    public let intent: Intent
    /// Ответ пользователю (живёт только в памяти).
    public let reply: String
    public let directive: AssistantDirective?
    /// Какие инструменты были выполнены (для обновления журнала в интерфейсе).
    public let executedActions: [ActionIdentifier]
    /// Действие ждёт подтверждения — `reply` содержит вопрос.
    public let pendingAction: PendingAction?

    public init(
        intent: Intent,
        reply: String,
        directive: AssistantDirective? = nil,
        executedActions: [ActionIdentifier] = [],
        pendingAction: PendingAction? = nil
    ) {
        self.intent = intent
        self.reply = reply
        self.directive = directive
        self.executedActions = executedActions
        self.pendingAction = pendingAction
    }
}

/// Настройки, с которыми обрабатывается команда.
public struct CommandContext: Sendable {
    public var locale: Locale
    public var personality: Personality
    public var confirmationPolicy: ConfirmationPolicy
    /// Поисковая система для «найди в интернете» (`google`, `yandex`, `duckduckgo`, `bing`).
    public var searchEngine: String

    public init(
        locale: Locale,
        personality: Personality = Personality(),
        confirmationPolicy: ConfirmationPolicy = ConfirmationPolicy(),
        searchEngine: String = "google"
    ) {
        self.locale = locale
        self.personality = personality
        self.confirmationPolicy = confirmationPolicy
        self.searchEngine = searchEngine
    }
}

/// Превращает фразу в действие и ответ.
///
/// Цепочка: правила → намерение → инструмент из реестра → проверка аргументов →
/// политика подтверждения (если нужно — вопрос пользователю) → выполнение → журнал → ответ.
/// Текст команды никуда не записывается: в журнал попадает только идентификатор действия.
@MainActor
public final class CommandProcessor {
    /// Шаг громкости для «громче» / «тише», проценты.
    public static let volumeStep = 10

    private let parser = RuleIntentParser()
    private let registry: ToolRegistry
    private let validator: ArgumentValidator
    private let auditLog: AuditLog
    private var composer: ResponseComposer
    private let log = JarvisLogger(category: "commands")

    public init(
        registry: ToolRegistry,
        auditLog: AuditLog,
        validator: ArgumentValidator = ArgumentValidator(),
        random: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.registry = registry
        self.auditLog = auditLog
        self.validator = validator
        self.composer = ResponseComposer(random: random)
    }

    public func handle(_ utterance: Utterance, source: CommandSource, context: CommandContext) async -> CommandOutcome {
        configureComposer(context)
        let intent = parser.parse(utterance.text)
        log.info("Command interpreted", .token("parser", "rules"), .bool("recognized", intent != .unknown))

        switch intent {
        case .currentTime:
            return await perform(BuiltInTools.currentTime, intent: intent, source: source, context: context)
        case .currentDate:
            return await perform(BuiltInTools.currentDate, intent: intent, source: source, context: context)
        case .openApp(let name):
            let attempt = await self.attempt(StandardTools.openApp, ["name": .string(name)], intent: intent, source: source, context: context)
            // Приложения нет, но это известный сайт («открой ютуб») — открываем сайт.
            if case .failed(.notFound(_), _) = attempt, let url = SiteDirectory.url(for: name) {
                return await perform(
                    StandardTools.openWebsite,
                    ["url": .string(url.absoluteString)],
                    intent: .openWebsite(name),
                    source: source,
                    context: context
                )
            }
            return finish(attempt, intent: intent)
        case .quitApp(let name):
            return await perform(StandardTools.quitApp, ["name": .string(name)], intent: intent, source: source, context: context)
        case .openWebsite(let site):
            guard let url = SiteDirectory.url(for: site) else {
                return CommandOutcome(intent: intent, reply: composer.text(for: .siteNotFound(site)))
            }
            return await perform(StandardTools.openWebsite, ["url": .string(url.absoluteString)], intent: intent, source: source, context: context)
        case .webSearch(let query):
            let arguments: [String: ArgumentValue] = ["query": .string(query), "engine": .string(context.searchEngine)]
            return await perform(StandardTools.webSearch, arguments, intent: intent, source: source, context: context)
        case .setVolume(let level):
            return await perform(StandardTools.setVolume, ["level": .integer(level)], intent: intent, source: source, context: context)
        case .changeVolume(let direction):
            let delta = direction == .up ? Self.volumeStep : -Self.volumeStep
            return await perform(StandardTools.changeVolume, ["delta": .integer(delta)], intent: intent, source: source, context: context)
        case .setMuted(let muted):
            return await perform(StandardTools.setMuted, ["muted": .boolean(muted)], intent: intent, source: source, context: context)
        case .disableAssistant:
            return CommandOutcome(intent: intent, reply: composer.reply(to: intent), directive: .disableAssistant)
        case .pauseMicrophone:
            return CommandOutcome(intent: intent, reply: composer.reply(to: intent), directive: .pauseMicrophone)
        case .setPrivacyMode(let enabled):
            return CommandOutcome(intent: intent, reply: composer.reply(to: intent), directive: .setPrivacyMode(enabled))
        case .empty, .greeting, .thanks, .capabilities, .cancel, .notYetSupported, .unknown:
            return CommandOutcome(intent: intent, reply: composer.reply(to: intent))
        }
    }

    /// Пользователь подтвердил: выполняется ровно тот вызов, который был показан.
    public func confirm(_ pending: PendingAction, context: CommandContext) async -> CommandOutcome {
        configureComposer(context)
        let result = await execute(pending.call, intent: pending.intent, source: pending.source, context: context, confirmed: true)
        return finish(result, intent: pending.intent)
    }

    /// Пользователь отказался (или не ответил): ничего не выполняется, в журнале — «отменено».
    public func decline(_ pending: PendingAction, reason: DeclineReason, context: CommandContext) async -> CommandOutcome {
        configureComposer(context)
        await record(pending.call.descriptor, source: pending.source, outcome: .cancelledByUser, confirmationRequired: true)
        let reply: ActionReply = switch reason {
        case .declined, .cancelled: .declined
        case .timedOut: .timedOut
        case .notUnderstood: .answerNotUnderstood
        }
        return CommandOutcome(intent: pending.intent, reply: composer.text(for: reply))
    }

    // MARK: - Выполнение

    private enum Attempt {
        case done(CommandOutcome)
        case failed(ToolFailure, ToolName)
    }

    private func perform(
        _ name: ToolName,
        _ arguments: [String: ArgumentValue] = [:],
        intent: Intent,
        source: CommandSource,
        context: CommandContext
    ) async -> CommandOutcome {
        finish(await attempt(name, arguments, intent: intent, source: source, context: context), intent: intent)
    }

    private func attempt(
        _ name: ToolName,
        _ arguments: [String: ArgumentValue],
        intent: Intent,
        source: CommandSource,
        context: CommandContext
    ) async -> Attempt {
        let prepared: PreparedToolCall
        do {
            prepared = try registry.prepare(ToolCall(toolName: name.rawValue, arguments: arguments), validator: validator)
        } catch {
            log.error("Tool preparation failed", .error(error))
            return .done(CommandOutcome(intent: intent, reply: composer.text(for: .failure)))
        }

        let descriptor = prepared.descriptor
        let requirement = context.confirmationPolicy.requirement(for: descriptor, context: PlanContext(source: source))
        guard case .required(let request) = requirement else {
            return await execute(prepared, intent: intent, source: source, context: context, confirmed: false)
        }

        // Сначала выясняем, что именно будет сделано (и существует ли цель), потом спрашиваем.
        let summary: String
        do {
            summary = try await prepared.tool.describe(prepared.arguments, context: ToolContext(source: source, locale: context.locale))
        } catch let failure as ToolFailure {
            return .failed(failure, descriptor.name)
        } catch {
            log.error("Tool description failed", .error(error))
            return .done(CommandOutcome(intent: intent, reply: composer.text(for: .failure)))
        }

        let pending = PendingAction(
            id: UUID(),
            summary: summary,
            allowsVoiceConfirmation: request.allowsVoiceConfirmation,
            isDangerous: request.reasons.contains(.dangerousAction) || request.reasons.contains(.bulkOperation),
            call: prepared,
            intent: intent,
            source: source
        )
        let question: ActionReply = request.allowsVoiceConfirmation
            ? .confirmationQuestion(summary)
            : .confirmationRequiredPhysically(summary)
        log.notice("Confirmation requested", .bool("voiceAllowed", request.allowsVoiceConfirmation))
        return .done(CommandOutcome(intent: intent, reply: composer.text(for: question), pendingAction: pending))
    }

    private func execute(
        _ prepared: PreparedToolCall,
        intent: Intent,
        source: CommandSource,
        context: CommandContext,
        confirmed: Bool
    ) async -> Attempt {
        let descriptor = prepared.descriptor
        do {
            let outcome = try await prepared.tool.run(prepared.arguments, context: ToolContext(source: source, locale: context.locale))
            await record(descriptor, source: source, outcome: .succeeded, confirmationRequired: confirmed, detail: outcome.auditDetail)
            return .done(CommandOutcome(
                intent: intent,
                reply: composer.reply(to: intent, value: outcome.message),
                executedActions: [descriptor.name]
            ))
        } catch let failure as ToolFailure {
            await record(descriptor, source: source, outcome: .failed, confirmationRequired: confirmed)
            return .failed(failure, descriptor.name)
        } catch {
            log.error("Tool failed", .error(error))
            await record(descriptor, source: source, outcome: .failed, confirmationRequired: confirmed)
            return .done(CommandOutcome(intent: intent, reply: composer.text(for: .failure)))
        }
    }

    private func finish(_ attempt: Attempt, intent: Intent) -> CommandOutcome {
        switch attempt {
        case .done(let outcome):
            return outcome
        case .failed(let failure, let tool):
            return CommandOutcome(intent: intent, reply: composer.text(for: Self.reply(for: failure, tool: tool)))
        }
    }

    static func reply(for failure: ToolFailure, tool: ToolName) -> ActionReply {
        switch failure {
        case .notFound(let target):
            tool == StandardTools.openWebsite ? .siteNotFound(target) : .appNotFound(target)
        case .notRunning(let target): .notRunning(target)
        case .protectedTarget(let target): .protectedApp(target)
        case .actionFailed(let target): .actionFailed(target)
        case .unsupported: .unsupported
        }
    }

    private func configureComposer(_ context: CommandContext) {
        composer.personality = context.personality
        composer.language = ResponseLanguage(locale: context.locale)
    }

    private func record(
        _ descriptor: ToolDescriptor,
        source: CommandSource,
        outcome: AuditOutcome,
        confirmationRequired: Bool = false,
        detail: AuditDetail? = nil
    ) async {
        do {
            try await auditLog.record(AuditEvent(
                action: descriptor.name,
                source: source,
                risk: descriptor.risk,
                outcome: outcome,
                confirmationRequired: confirmationRequired,
                detail: detail
            ))
        } catch {
            log.error("Audit record failed", .error(error))
        }
    }
}
