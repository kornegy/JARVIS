import JarvisCore

/// Обстоятельства, в которых выполняется шаг плана.
public struct PlanContext: Sendable, Equatable {
    public var source: CommandSource
    /// План видел недоверенный контент (файлы, письма, страницы).
    public var isTainted: Bool
    /// Сколько объектов затрагивает шаг (файлов, писем…).
    public var affectedItemCount: Int

    public init(source: CommandSource, isTainted: Bool = false, affectedItemCount: Int = 1) {
        self.source = source
        self.isTainted = isTainted
        self.affectedItemCount = affectedItemCount
    }
}

public enum ConfirmationReason: String, Sendable, CaseIterable {
    case consequentialAction
    case dangerousAction
    case untrustedContent
    case automation
    case bulkOperation
}

public struct ConfirmationRequest: Sendable, Equatable {
    public let reasons: Set<ConfirmationReason>
    /// `false` — подтвердить можно только физически (кнопкой или клавишей), не голосом.
    public let allowsVoiceConfirmation: Bool
}

public enum ConfirmationRequirement: Sendable, Equatable {
    case notRequired
    case required(ConfirmationRequest)

    public var isRequired: Bool {
        if case .required(_) = self { return true }
        return false
    }
}

/// Политика подтверждения действий (docs/Security.md §5–6). Чистая функция — легко тестировать.
///
/// Правила:
/// 1. Категория 3 (`dangerous`) — подтверждение **всегда**; голосом — только если пользователь
///    это разрешил и план не испачкан недоверенным контентом.
/// 2. Категория 2 (`consequential`) — подтверждение по настройке; **всегда** для автоматизаций.
/// 3. Массовая операция (больше `bulkThreshold` объектов) категории 2 поднимается до категории 3.
/// 4. Испачканный план: любое действие, кроме чтения, требует подтверждения.
/// 5. Категория 1 (`safe`) без недоверенного контента выполняется сразу.
public struct ConfirmationPolicy: Sendable, Equatable {
    public static let bulkThreshold = 10

    public var confirmConsequentialActions: Bool
    public var allowVoiceConfirmationForDangerousActions: Bool

    public init(confirmConsequentialActions: Bool = true, allowVoiceConfirmationForDangerousActions: Bool = false) {
        self.confirmConsequentialActions = confirmConsequentialActions
        self.allowVoiceConfirmationForDangerousActions = allowVoiceConfirmationForDangerousActions
    }

    public func requirement(for descriptor: ToolDescriptor, context: PlanContext) -> ConfirmationRequirement {
        var reasons: Set<ConfirmationReason> = []
        var effectiveRisk = descriptor.risk

        if descriptor.risk >= .consequential, context.affectedItemCount > ConfirmationPolicy.bulkThreshold {
            effectiveRisk = .dangerous
            reasons.insert(.bulkOperation)
        }

        switch effectiveRisk {
        case .dangerous:
            reasons.insert(.dangerousAction)
            if context.source == .automation { reasons.insert(.automation) }
        case .consequential:
            if confirmConsequentialActions { reasons.insert(.consequentialAction) }
            if context.source == .automation { reasons.insert(.automation) }
        case .safe:
            break
        }

        if context.isTainted, descriptor.effect != .readOnly {
            reasons.insert(.untrustedContent)
        }

        guard !reasons.isEmpty else { return .notRequired }

        let voiceAllowed = effectiveRisk != .dangerous
            || (allowVoiceConfirmationForDangerousActions && !context.isTainted)
        return .required(ConfirmationRequest(reasons: reasons, allowsVoiceConfirmation: voiceAllowed))
    }
}
