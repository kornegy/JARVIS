import Testing
@testable import JarvisCore

@Suite("Машина состояний ассистента")
struct AssistantStateMachineTests {
    /// Применяет события по очереди; возвращает `false`, если хотя бы одно отклонено.
    private func apply(_ events: [AssistantEvent], to machine: inout AssistantStateMachine) -> Bool {
        var allAccepted = true
        for event in events where !machine.handle(event) {
            allAccepted = false
        }
        return allAccepted
    }

    @Test("По умолчанию ассистент выключен и использует Push-to-Talk")
    func initialState() {
        let machine = AssistantStateMachine()
        #expect(machine.state == .disabled)
        #expect(machine.listeningMode == .pushToTalk)
        #expect(!machine.isMicrophonePaused)
    }

    @Test("Включение переводит в ожидание в выбранном режиме")
    func enableEntersIdle() {
        var pushToTalk = AssistantStateMachine(listeningMode: .pushToTalk)
        pushToTalk.handle(.enable)
        #expect(pushToTalk.state == .idle(.pushToTalk))

        var wakeWord = AssistantStateMachine(listeningMode: .wakeWord)
        wakeWord.handle(.enable)
        #expect(wakeWord.state == .idle(.wakeWord))
    }

    @Test("Выключить можно из любого состояния")
    func disableAlwaysAllowed() {
        let paths: [[AssistantEvent]] = [
            [],
            [.enable],
            [.enable, .pauseMicrophone],
            [.enable, .wakeWordDetected],
            [.enable, .wakeWordDetected, .utteranceCaptured],
            [.enable, .wakeWordDetected, .utteranceCaptured, .planReady(requiresConfirmation: true)],
            [.enable, .wakeWordDetected, .utteranceCaptured, .planReady(requiresConfirmation: false)],
            [.enable, .speechStarted],
            [.enable, .failed(.internalError)],
        ]
        for path in paths {
            var machine = AssistantStateMachine(listeningMode: .wakeWord)
            let reached = apply(path, to: &machine)
            #expect(reached)
            #expect(machine.canHandle(.disable))
            machine.handle(.disable)
            #expect(machine.state == .disabled)
        }
    }

    @Test("Полный цикл голосовой команды с подтверждением")
    func fullCommandCycle() {
        var machine = AssistantStateMachine(listeningMode: .wakeWord)
        machine.handle(.enable)
        machine.handle(.wakeWordDetected)
        #expect(machine.state == .listening)
        machine.handle(.utteranceCaptured)
        #expect(machine.state == .processing)
        machine.handle(.planReady(requiresConfirmation: true))
        #expect(machine.state == .awaitingConfirmation)
        machine.handle(.confirmationResolved(approved: true))
        #expect(machine.state == .executing)
        machine.handle(.speechStarted)
        #expect(machine.state == .speaking)
        machine.handle(.speechFinished)
        #expect(machine.state == .idle(.wakeWord))
    }

    @Test("Отказ в подтверждении возвращает в ожидание без выполнения")
    func deniedConfirmationReturnsToIdle() {
        var machine = AssistantStateMachine(listeningMode: .pushToTalk)
        let reached = apply([.enable, .pushToTalkPressed, .utteranceCaptured, .planReady(requiresConfirmation: true)], to: &machine)
        #expect(reached)
        machine.handle(.confirmationResolved(approved: false))
        #expect(machine.state == .idle(.pushToTalk))
    }

    @Test("Недопустимые переходы отклоняются и не меняют состояние")
    func invalidTransitionsAreRejected() {
        var machine = AssistantStateMachine(listeningMode: .wakeWord)
        #expect(!machine.canHandle(.wakeWordDetected))
        #expect(!machine.canHandle(.pushToTalkPressed))
        #expect(!machine.canHandle(.pauseMicrophone))
        #expect(!machine.canHandle(.failed(.microphoneUnavailable)))

        let rejected = machine.handle(.utteranceCaptured)
        #expect(!rejected)
        #expect(machine.state == .disabled)

        machine.handle(.enable)
        #expect(!machine.canHandle(.utteranceCaptured))
        #expect(!machine.canHandle(.confirmationResolved(approved: true)))
        #expect(!machine.canHandle(.enable))
        #expect(machine.state == .idle(.wakeWord))
    }

    @Test("Wake word не работает в режиме Push-to-Talk")
    func wakeWordIgnoredInPushToTalkMode() {
        var machine = AssistantStateMachine(listeningMode: .pushToTalk)
        machine.handle(.enable)
        #expect(!machine.canHandle(.wakeWordDetected))
        #expect(machine.canHandle(.pushToTalkPressed))
    }

    @Test("Пауза микрофона прерывает прослушивание и сохраняется после команды")
    func microphonePause() {
        var machine = AssistantStateMachine(listeningMode: .wakeWord)
        machine.handle(.enable)
        machine.handle(.wakeWordDetected)
        machine.handle(.pauseMicrophone)
        #expect(machine.state == .idle(.microphonePaused))
        #expect(machine.isMicrophonePaused)
        #expect(!machine.canHandle(.wakeWordDetected))

        // Push-to-Talk — явное действие пользователя, поэтому работает и на паузе.
        let completed = apply([.pushToTalkPressed, .utteranceCaptured, .planReady(requiresConfirmation: false), .executionFinished], to: &machine)
        #expect(completed)
        #expect(machine.state == .idle(.microphonePaused))

        machine.handle(.resumeMicrophone)
        #expect(machine.state == .idle(.wakeWord))
    }

    @Test("Смена режима прослушивания в ожидании сразу меняет состояние")
    func changeListeningMode() {
        var machine = AssistantStateMachine(listeningMode: .pushToTalk)
        machine.handle(.enable)
        machine.handle(.setListeningMode(.wakeWord))
        #expect(machine.state == .idle(.wakeWord))
        #expect(machine.listeningMode == .wakeWord)
    }

    @Test("Перебивание: Push-to-Talk во время ответа")
    func bargeIn() {
        var machine = AssistantStateMachine()
        machine.handle(.enable)
        machine.handle(.speechStarted)
        #expect(machine.state == .speaking)
        machine.handle(.pushToTalkPressed)
        #expect(machine.state == .listening)
    }

    @Test("Ошибка и восстановление")
    func failureAndRecovery() {
        var machine = AssistantStateMachine()
        machine.handle(.enable)
        machine.handle(.failed(.microphoneUnavailable))
        #expect(machine.state == .failed(.microphoneUnavailable))
        machine.handle(.recover)
        #expect(machine.state == .idle(.pushToTalk))
    }

    @Test("У каждого состояния есть заголовок и значок")
    func everyStateHasPresentation() {
        let states: [AssistantState] = [
            .disabled, .idle(.wakeWord), .idle(.pushToTalk), .idle(.microphonePaused),
            .listening, .processing, .executing, .awaitingConfirmation, .speaking, .failed(.internalError),
        ]
        for state in states {
            #expect(!state.presentation.title.isEmpty)
            #expect(!state.presentation.symbolName.isEmpty)
        }
        #expect(AssistantState.disabled.presentation.title == "Выключен")
        #expect(AssistantState.idle(.pushToTalk).presentation.title == "Готов")
        #expect(AssistantState.failed(.internalError).presentation.tone == .error)
        for code in FailureCode.allCases {
            #expect(!code.userMessage.isEmpty)
        }
    }
}
