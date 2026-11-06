/// Как показать состояние пользователю: текст, SF Symbol и «тон» для цвета.
///
/// Лежит в ядре, а не в UI, чтобы соответствие «состояние → вид» проверялось тестами.
public struct AssistantStatePresentation: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case inactive
        case ready
        case active
        case attention
        case error
    }

    public let title: String
    public let symbolName: String
    public let tone: Tone
}

extension AssistantState {
    public var presentation: AssistantStatePresentation {
        switch self {
        case .disabled:
            .init(title: "Выключен", symbolName: "circle.slash", tone: .inactive)
        case .idle(.wakeWord), .idle(.pushToTalk):
            .init(title: "Готов", symbolName: "waveform", tone: .ready)
        case .idle(.microphonePaused):
            .init(title: "Микрофон на паузе", symbolName: "mic.slash", tone: .inactive)
        case .listening:
            .init(title: "Слушаю", symbolName: "waveform.circle.fill", tone: .active)
        case .processing:
            .init(title: "Думаю", symbolName: "ellipsis.circle", tone: .active)
        case .executing:
            .init(title: "Выполняю", symbolName: "gearshape.2", tone: .active)
        case .awaitingConfirmation:
            .init(title: "Жду подтверждения", symbolName: "questionmark.circle", tone: .attention)
        case .speaking:
            .init(title: "Говорю", symbolName: "speaker.wave.2", tone: .active)
        case .failed:
            .init(title: "Ошибка", symbolName: "exclamationmark.triangle", tone: .error)
        }
    }
}
