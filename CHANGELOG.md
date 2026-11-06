# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии — [SemVer](https://semver.org/lang/ru/).

## [Unreleased]

### Добавлено — Phase 1: фундамент проекта
- Swift Package `JarvisKit`: модули `JarvisCore`, `JarvisSettings`, `JarvisTools`.
- Машина состояний ассистента (Disabled, Idle, Listening, Processing, Executing,
  Waiting for Confirmation, Speaking, Error).
- Приватные типы `Utterance` и `Sensitive`, логгер только со статическими строками.
- Журнал аудита (JSON Lines, права 0600, срок хранения, очистка, минимальный/подробный режим).
- Настройки с приватными значениями по умолчанию, миграциями, резервными копиями и
  восстановлением после повреждения.
- Интерфейсы инструментов: `Tool`, `ToolRegistry`, строгая валидация аргументов,
  политика подтверждения действий.
- Приложение в строке меню: статус, включение/выключение, пауза микрофона, честный
  индикатор микрофона, Privacy Mode, окно JARVIS, журнал действий, настройки, автозапуск.
- XcodeGen-проект, Makefile, privacy-lint, CI на macOS (юнит-тесты, Release-сборка, UI-тест).

### Добавлено — Phase 0: исследование и архитектура
- Документы: Architecture, TechnologyComparison, Security, Privacy, Roadmap, PerformanceTargets.

### Ещё не реализовано
- Голос (wake word, Push-to-Talk, распознавание, синтез речи) — Phase 2.
- Управление macOS, разрешения, исполнитель команд — Phase 3.
- AI-провайдеры, память, автоматизации — Phase 4.
