import Testing
import JarvisCore
@testable import JarvisTools

@Suite("Политика подтверждения (тесты безопасности)")
struct ConfirmationPolicyTests {
    private func tool(_ risk: RiskLevel, _ effect: ToolEffect) -> ToolDescriptor {
        ToolDescriptor(name: "test.tool", summary: "Тест", risk: risk, effect: effect)
    }

    private func request(_ requirement: ConfirmationRequirement) -> ConfirmationRequest? {
        if case .required(let request) = requirement { return request }
        return nil
    }

    @Test("Безопасное действие выполняется без подтверждения")
    func safeActionRunsImmediately() {
        let policy = ConfirmationPolicy()
        for source in CommandSource.allCases {
            #expect(policy.requirement(for: tool(.safe, .local), context: PlanContext(source: source)) == .notRequired)
        }
    }

    @Test("Опасное действие требует подтверждения всегда, даже если подтверждения категории 2 выключены")
    func dangerousAlwaysConfirmed() {
        let policy = ConfirmationPolicy(confirmConsequentialActions: false)
        let result = request(policy.requirement(for: tool(.dangerous, .external), context: PlanContext(source: .voiceWakeWord)))
        #expect(result?.reasons.contains(.dangerousAction) == true)
        #expect(result?.allowsVoiceConfirmation == false) // по умолчанию — только физически
    }

    @Test("Голосовое подтверждение опасного действия — только если разрешено и план чистый")
    func voiceConfirmationForDangerous() {
        let policy = ConfirmationPolicy(allowVoiceConfirmationForDangerousActions: true)
        let clean = request(policy.requirement(for: tool(.dangerous, .local), context: PlanContext(source: .voicePushToTalk)))
        #expect(clean?.allowsVoiceConfirmation == true)

        let tainted = request(policy.requirement(for: tool(.dangerous, .local), context: PlanContext(source: .voicePushToTalk, isTainted: true)))
        #expect(tainted?.allowsVoiceConfirmation == false)
        #expect(tainted?.reasons.contains(.untrustedContent) == true)
    }

    @Test("Категория 2 подтверждается по настройке")
    func consequentialFollowsSetting() {
        let context = PlanContext(source: .typedText)
        let on = request(ConfirmationPolicy(confirmConsequentialActions: true).requirement(for: tool(.consequential, .local), context: context))
        #expect(on?.reasons == [.consequentialAction])
        #expect(on?.allowsVoiceConfirmation == true)

        let off = ConfirmationPolicy(confirmConsequentialActions: false).requirement(for: tool(.consequential, .local), context: context)
        #expect(off == .notRequired)
    }

    @Test("Автоматизации подтверждают категорию 2 всегда")
    func automationsConfirmConsequential() {
        let policy = ConfirmationPolicy(confirmConsequentialActions: false)
        let result = request(policy.requirement(for: tool(.consequential, .local), context: PlanContext(source: .automation)))
        #expect(result?.reasons == [.automation])
    }

    @Test("Массовая операция поднимается до категории 3")
    func bulkOperationsEscalate() {
        let policy = ConfirmationPolicy(confirmConsequentialActions: false, allowVoiceConfirmationForDangerousActions: false)
        let context = PlanContext(source: .voiceWakeWord, affectedItemCount: ConfirmationPolicy.bulkThreshold + 1)
        let result = request(policy.requirement(for: tool(.consequential, .local), context: context))
        #expect(result?.reasons.isSuperset(of: [.bulkOperation, .dangerousAction]) == true)
        #expect(result?.allowsVoiceConfirmation == false)

        // Чтение многих объектов — не массовое изменение.
        let read = policy.requirement(for: tool(.safe, .readOnly), context: context)
        #expect(read == .notRequired)
    }

    @Test("Испачканный план: любое изменение требует подтверждения, чтение — нет")
    func taintedPlans() {
        let policy = ConfirmationPolicy()
        let tainted = PlanContext(source: .voiceWakeWord, isTainted: true)

        let open = request(policy.requirement(for: tool(.safe, .local), context: tainted))
        #expect(open?.reasons == [.untrustedContent])

        let read = policy.requirement(for: tool(.safe, .readOnly), context: tainted)
        #expect(read == .notRequired)
    }

    @Test("Ни одна комбинация не пропускает опасное действие без подтверждения")
    func exhaustiveDangerousCheck() {
        for confirmConsequential in [true, false] {
            for allowVoice in [true, false] {
                let policy = ConfirmationPolicy(confirmConsequentialActions: confirmConsequential, allowVoiceConfirmationForDangerousActions: allowVoice)
                for source in CommandSource.allCases {
                    for tainted in [true, false] {
                        for effect in ToolEffect.allCases {
                            let context = PlanContext(source: source, isTainted: tainted)
                            #expect(policy.requirement(for: tool(.dangerous, effect), context: context).isRequired)
                        }
                    }
                }
            }
        }
    }
}
