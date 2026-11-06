import XCTest

/// UI-тесты: запуск, включение/выключение, текстовая команда.
/// Данные UI-тестов пишутся во временную папку (`--ui-testing`), автозапуск и горячая клавиша
/// не трогаются; режим по умолчанию — Push-to-Talk, поэтому микрофон в тестах не используется.
final class LaunchUITests: XCTestCase {
    @MainActor
    func testLaunchShowsStatusAndPowerButtonTogglesAssistant() throws {
        continueAfterFailure = false
        let app = launchApp()
        defer { app.terminate() }

        let status = app.staticTexts["status.title"]
        let appeared = status.waitForExistence(timeout: 30)
        XCTAssertTrue(appeared, "Главное окно со статусом не появилось")

        let initial = Self.text(of: status)
        XCTAssertEqual(initial, "Выключен")

        let power = app.buttons["assistant.power"]
        let powerExists = power.waitForExistence(timeout: 10)
        XCTAssertTrue(powerExists, "Нет кнопки включения")

        power.click()
        let enabled = Self.wait(timeout: 10) { Self.text(of: status) == "Готов" }
        let afterEnable = Self.text(of: status)
        XCTAssertTrue(enabled, "Статус после включения: \(afterEnable)")

        let hint = app.staticTexts["voice.hint"]
        let hintShown = hint.waitForExistence(timeout: 5)
        XCTAssertTrue(hintShown, "Нет подсказки, как обратиться к ассистенту")

        let microphone = app.descendants(matching: .any)["microphone.indicator"].firstMatch.exists
        XCTAssertTrue(microphone, "Нет индикатора микрофона")

        power.click()
        let disabled = Self.wait(timeout: 10) { Self.text(of: status) == "Выключен" }
        let afterDisable = Self.text(of: status)
        XCTAssertTrue(disabled, "Статус после выключения: \(afterDisable)")
    }

    @MainActor
    func testTypedCommandGetsAnswer() throws {
        continueAfterFailure = false
        let app = launchApp()
        defer { app.terminate() }

        let power = app.buttons["assistant.power"]
        let powerExists = power.waitForExistence(timeout: 30)
        XCTAssertTrue(powerExists, "Нет кнопки включения")
        power.click()

        let field = app.textFields["command.field"]
        let fieldExists = field.waitForExistence(timeout: 10)
        XCTAssertTrue(fieldExists, "Нет поля для текстовой команды")
        let fieldEnabled = Self.wait(timeout: 10) { field.isEnabled }
        XCTAssertTrue(fieldEnabled, "Поле команды недоступно после включения")

        field.click()
        field.typeText("what time is it")
        field.typeKey(.return, modifierFlags: [])

        let reply = app.staticTexts["assistant.reply"]
        let replied = reply.waitForExistence(timeout: 10)
        XCTAssertTrue(replied, "Нет ответа на текстовую команду")
        let replyText = Self.text(of: reply)
        XCTAssertTrue(replyText.hasPrefix("Сейчас"), "Неожиданный ответ: \(replyText)")
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--show-main-window"]
        app.launch()
        return app
    }

    @MainActor
    private static func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    @MainActor
    private static func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
