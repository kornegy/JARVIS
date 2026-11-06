import XCTest

/// UI-тест запуска: приложение стартует, показывает статус, кнопка питания меняет состояние.
/// Данные UI-тестов пишутся во временную папку (`--ui-testing`), автозапуск не трогается.
final class LaunchUITests: XCTestCase {
    @MainActor
    func testLaunchShowsStatusAndPowerButtonTogglesAssistant() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--show-main-window"]
        app.launch()
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

        let voiceNote = app.staticTexts["voice.unavailable"]
        let noteShown = voiceNote.waitForExistence(timeout: 5)
        XCTAssertTrue(noteShown, "Нет честного сообщения о том, что голос ещё не реализован")

        let microphone = app.descendants(matching: .any)["microphone.indicator"].firstMatch.exists
        XCTAssertTrue(microphone, "Нет индикатора микрофона")

        power.click()
        let disabled = Self.wait(timeout: 10) { Self.text(of: status) == "Выключен" }
        let afterDisable = Self.text(of: status)
        XCTAssertTrue(disabled, "Статус после выключения: \(afterDisable)")
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
