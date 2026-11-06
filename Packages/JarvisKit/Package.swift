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
    ],
    targets: [
        // Ядро: состояния ассистента, приватные типы, логгер, хранилище, журнал аудита.
        // Не зависит ни от одного другого модуля.
        .target(name: "JarvisCore"),

        // Настройки: модель, значения по умолчанию, хранение и миграции.
        .target(name: "JarvisSettings", dependencies: ["JarvisCore"]),

        // Инструменты: описание действий, реестр, валидация аргументов, политика подтверждения.
        .target(name: "JarvisTools", dependencies: ["JarvisCore"]),

        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisSettingsTests", dependencies: ["JarvisSettings", "JarvisCore"]),
        .testTarget(name: "JarvisToolsTests", dependencies: ["JarvisTools", "JarvisCore"]),
    ],
    swiftLanguageModes: [.v6]
)
