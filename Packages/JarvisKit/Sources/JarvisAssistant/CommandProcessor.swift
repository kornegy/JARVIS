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

/// Результат обработки команды.
public struct CommandOutcome: Sendable, Equatable {
    public let intent: Intent
    /// Ответ пользователю (живёт только в памяти).
    public let reply: String
    public let directive: AssistantDirective?
    /// Какие инструменты были выполнены (для обновления журнала в интерфейсе).
    public let executedActions: [ActionIdentifier]

    public init(intent: Intent, reply: String, directive: AssistantDirective? = nil, executedActions: [ActionIdentifier] = []) {
        self.intent = intent
        self.reply = reply
        self.directive = directive
        self.executedActions = executedActions
    }
}

/// Настройки, с которыми обрабатывается команда.
public struct CommandContext: Sendable {
    public var locale: Locale
    public var personality: Personality
    public var confirmationPolicy: ConfirmationPolicy

    public init(locale: Locale, personality: Personality = Personality(), confirmationPolicy: ConfirmationPolicy = ConfirmationPolicy()) {
        self.locale = locale
        self.personality = personality
        self.confirmationPolicy = confirmationPolicy
    }
}

/// Превращает фразу в действие и ответ.
///
/// Цепочка: правила → намерение → (если нужно) инструмент из реестра → проверка аргументов →
/// политика подтверждения → выполнение → запись в журнал → ответ с характером.
/// Текст команды никуда не записывается: в журнал попадает только идентификатор действия.
@MainActor
public final class CommandProcessor {
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
        composer.personality = context.personality
        composer.language = ResponseLanguage(locale: context.locale)

        let intent = parser.parse(utterance.text)
        log.info("Command interpreted", .token("parser", "rules"), .bool("recognized", intent != .unknown))

        switch intent {
        case .currentTime:
            return await run(BuiltInTools.currentTime, for: intent, source: source, context: context)
        case .currentDate:
            return await run(BuiltInTools.currentDate, for: intent, source: source, context: context)
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

    private func run(_ name: ToolName, for intent: Intent, source: CommandSource, context: CommandContext) async -> CommandOutcome {
        let prepared: PreparedToolCall
        do {
            prepared = try registry.prepare(ToolCall(toolName: name.rawValue), validator: validator)
        } catch {
            log.error("Tool preparation failed", .error(error))
            return CommandOutcome(intent: intent, reply: failureReply(context))
        }

        let descriptor = prepared.descriptor
        let requirement = context.confirmationPolicy.requirement(for: descriptor, context: PlanContext(source: source))
        if requirement.isRequired {
            // Окно подтверждения появится в Phase 3; до тех пор такие действия не выполняются.
            await record(descriptor, source: source, outcome: .deniedByPolicy, confirmationRequired: true)
            return CommandOutcome(intent: intent, reply: confirmationUnavailableReply(context))
        }

        do {
            let outcome = try await prepared.tool.run(prepared.arguments, context: ToolContext(source: source, locale: context.locale))
            await record(descriptor, source: source, outcome: .succeeded, detail: outcome.auditDetail)
            return CommandOutcome(intent: intent, reply: composer.reply(to: intent, value: outcome.message), executedActions: [name])
        } catch {
            log.error("Tool failed", .error(error))
            await record(descriptor, source: source, outcome: .failed)
            return CommandOutcome(intent: intent, reply: failureReply(context))
        }
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

    private func failureReply(_ context: CommandContext) -> String {
        ResponseLanguage(locale: context.locale) == .english
            ? "Something went wrong. Please try again."
            : "Что-то пошло не так. Попробуй ещё раз."
    }

    private func confirmationUnavailableReply(_ context: CommandContext) -> String {
        ResponseLanguage(locale: context.locale) == .english
            ? "This action needs your confirmation, and confirmations arrive in the next version."
            : "Это действие требует подтверждения, а подтверждения появятся в следующей версии."
    }
}
