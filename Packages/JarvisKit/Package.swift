// swift-tools-version: 6.2
//
// JarvisKit — вся логика JARVIS, разбитая на модули.
// Приложение (App/) только собирает модули вместе и рисует интерфейс.
// Модули можно собирать и тестировать без Xcode-проекта: `swift test`.

import PackageDescription

let package = Package(
    name: "JarvisKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
        .library(name: "JarvisSettings", targets: ["JarvisSettings"]),
        .library(name: "JarvisTools", targets: ["JarvisTools"]),
        .library(name: "JarvisAI", targets: ["JarvisAI"]),
        .library(name: "JarvisAssistant", targets: ["JarvisAssistant"]),
        .library(name: "JarvisVoice", targets: ["JarvisVoice"]),
    ],
    targets: [
        // Ядро: состояния ассистента, приватные типы, логгер, хранилище, журнал аудита.
        // Не зависит ни от одного другого модуля.
        .target(name: "JarvisCore"),

        // Настройки: модель, значения по умолчанию, хранение и миграции.
        .target(name: "JarvisSettings", dependencies: ["JarvisCore"]),

        // Инструменты: описание действий, реестр, валидация аргументов, политика подтверждения.
        .target(name: "JarvisTools", dependencies: ["JarvisCore"]),

        // Язык: нормализация текста, фраза-активатор, разбор команд по правилам, ответы с характером.
        // Не зависит от платформы и сети.
        .target(name: "JarvisAI"),

        // Оркестратор: сборка команды из речи, обработка, ответ, машина состояний.
        // Системные части (микрофон, распознавание, синтез) — через протоколы.
        .target(
            name: "JarvisAssistant",
            dependencies: ["JarvisCore", "JarvisSettings", "JarvisTools", "JarvisAI"]
        ),

        // macOS-движки: микрофон, распознавание речи на устройстве (SpeechAnalyzer),
        // синтез речи, разрешения, горячая клавиша Push-to-Talk.
        .target(
            name: "JarvisVoice",
            dependencies: ["JarvisCore", "JarvisSettings", "JarvisAssistant"]
        ),

        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisSettingsTests", dependencies: ["JarvisSettings", "JarvisCore"]),
        .testTarget(name: "JarvisToolsTests", dependencies: ["JarvisTools", "JarvisCore"]),
        .testTarget(name: "JarvisAITests", dependencies: ["JarvisAI"]),
        .testTarget(
            name: "JarvisAssistantTests",
            dependencies: ["JarvisAssistant", "JarvisAI", "JarvisCore", "JarvisSettings", "JarvisTools"]
        ),
        .testTarget(name: "JarvisVoiceTests", dependencies: ["JarvisVoice", "JarvisAssistant", "JarvisSettings"]),
    ],
    swiftLanguageModes: [.v6]
)
