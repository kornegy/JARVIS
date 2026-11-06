import Foundation
import SwiftUI
import JarvisCore

// Человекочитаемые названия для интерфейса.

extension ActionIdentifier {
    var displayName: String {
        switch rawValue {
        case "assistant.enable": "JARVIS включён"
        case "assistant.disable": "JARVIS выключен"
        case "microphone.pause": "Микрофон на паузе"
        case "microphone.resume": "Микрофон снят с паузы"
        case "privacy_mode.enable": "Privacy Mode включён"
        case "privacy_mode.disable": "Privacy Mode выключен"
        default: rawValue
        }
    }
}

extension CommandSource {
    var displayName: String {
        switch self {
        case .voiceWakeWord: "Голос"
        case .voicePushToTalk: "Push-to-Talk"
        case .typedText: "Текст"
        case .automation: "Автоматизация"
        case .userInterface: "Интерфейс"
        }
    }
}

extension AuditOutcome {
    var displayName: String {
        switch self {
        case .succeeded: "Выполнено"
        case .failed: "Ошибка"
        case .cancelledByUser: "Отменено"
        case .deniedByPolicy: "Запрещено политикой"
        case .permissionMissing: "Нет разрешения"
        }
    }

    var symbolName: String {
        switch self {
        case .succeeded: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .cancelledByUser: "arrow.uturn.backward.circle"
        case .deniedByPolicy: "hand.raised"
        case .permissionMissing: "lock"
        }
    }

    var color: Color {
        switch self {
        case .succeeded: Color.green
        case .failed, .deniedByPolicy: Color.red
        case .cancelledByUser, .permissionMissing: Color.orange
        }
    }
}

extension AuditEntry {
    var confirmationText: String {
        guard confirmationRequired else { return "Не требовалось" }
        switch confirmed {
        case true?: return "Подтверждено"
        case false?: return "Отклонено"
        case nil: return "Требовалось"
        }
    }
}

extension AuditDetailLevel {
    var displayName: String {
        switch self {
        case .minimal: "Минимальный"
        case .detailed: "Подробный"
        }
    }
}

extension AssistantStatePresentation.Tone {
    var color: Color {
        switch self {
        case .inactive: Color.secondary
        case .ready: Color.green
        case .active: Color.accentColor
        case .attention: Color.orange
        case .error: Color.red
        }
    }
}

extension Bundle {
    var versionDescription: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
