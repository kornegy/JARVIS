# JARVIS — Разработка

## 1. Что нужно установить

| Инструмент | Зачем | Как |
|---|---|---|
| macOS 26+ на Apple Silicon | целевая платформа | — |
| Xcode 26+ (рекомендуется последняя стабильная) | компилятор Swift 6, SDK macOS | App Store |
| XcodeGen | генерирует `JARVIS.xcodeproj` из `project.yml` | `brew install xcodegen` |

Сторонних библиотек в приложении нет — `swift test` и сборка не скачивают зависимости.

### Xcode, а не Command Line Tools

Если `make` пишет «активны Command Line Tools» (или xcodebuild жалуется
`requires Xcode, but active developer directory … is a command line tools instance`),
значит, установлена или выбрана не та версия инструментов. Нужна полная Xcode:

```bash
ls /Applications | grep -i xcode
```

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

```bash
sudo xcodebuild -license accept
```

```bash
xcodebuild -runFirstLaunch
```

Если первая команда ничего не нашла — установите Xcode из App Store. Проверка
`scripts/check-xcode.sh` запускается автоматически перед `make test`, `make run` и т.д.

## 2. Первый запуск

```bash
git clone https://github.com/kornegy/JARVIS.git
```

```bash
cd JARVIS && make test
```

```bash
make run
```

`make run` генерирует Xcode-проект, собирает Debug и открывает `JARVIS.app`. В строке меню
появится иконка JARVIS, а при первом запуске — небольшое окно со статусом.

Для замеров процессора и памяти запускай оптимизированную сборку — `make run-release`
(Debug-сборка медленнее и показывает завышенную нагрузку). Текущие CPU и память JARVIS
видны внизу главного окна.

Работа в Xcode: `make project`, затем `open JARVIS.xcodeproj` и ⌘R. Логику модулей удобно
разбирать, открыв `Packages/JarvisKit/Package.swift` отдельно — тесты запускаются ⌘U.

## 3. Подпись (важно для разрешений macOS)

По умолчанию сборка подписывается **ad-hoc** (`-`). Этого достаточно, чтобы запускать
приложение на своём Mac, но у ad-hoc подписи есть неприятное свойство: после каждой
пересборки macOS считает приложение новым и **сбрасывает выданные разрешения**
(микрофон, Accessibility и т.д.). Начиная с Phase 2 это станет заметно.

Решение — бесплатный сертификат **Apple Development** (платный аккаунт не нужен):

1. Xcode → Settings → Accounts → добавить свой Apple ID (создастся Personal Team).
2. Узнать Team ID: Xcode → Settings → Accounts → команда → поле Team ID
   (или в Keychain Access сертификат «Apple Development: …» → Organizational Unit).
3. Собирать с ним:

```bash
make run TEAM=ABCDE12345
```

Developer ID и нотаризация нужны только для раздачи приложения другим людям —
см. [Release.md](Release.md).

## 4. Структура кода

```
App/Sources/                 приложение (тонкий слой)
  JARVISApp.swift            сцены: строка меню, окно, журнал, настройки
  AppModel.swift             состояние для UI + связывание модулей
  LoginItemController.swift  автозапуск (SMAppService)
  Views/                     SwiftUI-представления
Packages/JarvisKit/Sources/
  JarvisCore/
    State/                   AssistantState, машина состояний, отображение состояний
    Privacy/                 Utterance, Sensitive — типы, которые не «протекают»
    Logging/                 JarvisLogger — логгер только со статическими строками
    Storage/                 папки данных, атомарная запись 0600, резервные копии
    Audit/                   журнал аудита, идентификаторы действий, общие типы
  JarvisSettings/            модель настроек, хранилище, миграции
  JarvisTools/               Tool, реестр, валидация аргументов, политика подтверждения
```

### Как изучать модули (рекомендуемый порядок)

1. `AssistantStateMachine.swift` + его тесты — как устроены состояния и почему «выключить»
   разрешено всегда.
2. `Utterance.swift` и `JarvisLogger.swift` — как типы защищают приватность на уровне
   компилятора.
3. `JarvisSettings.swift` → `SettingsStore.swift` — значения по умолчанию, совместимость,
   миграции, что происходит с повреждённым файлом.
4. `ToolDescriptor.swift` → `ArgumentValidator.swift` → `ConfirmationPolicy.swift` —
   как будущие команды будут проходить проверки безопасности.
5. `AppModel.swift` — как всё это связано с интерфейсом.

Каждый тест — это пример использования модуля: сначала читай тест, потом код.

## 5. Правила кода

* Swift 6, strict concurrency; предупреждения = ошибки (в CI и `make test`).
* Логирование — только `JarvisLogger`; никаких `print`. Проверяет `scripts/privacy-lint.sh`.
* Новые функции — с тестами. Новый модуль — только вместе с реальной реализацией.
* Новые зависимости и entitlements — только с обоснованием в документации.
* Комментарии и документация — на русском, идентификаторы — на английском.
* Коммиты — логически завершённые шаги; каждый должен проходить CI.

## 6. Полезные команды

| Команда | Что делает |
|---|---|
| `make test` | privacy-lint + юнит-тесты пакета |
| `make test-ui` | UI-тест запуска приложения |
| `make release` | Release-сборка + размер `.app` |
| `make clean` | удалить сборки и сгенерированный проект |
| `log stream --predicate 'subsystem == "io.github.kornegy.jarvis"'` | смотреть логи JARVIS вживую |
| `open ~/Library/Application\ Support/JARVIS` | папка данных |

## 7. CI

GitHub Actions (`.github/workflows/ci.yml`) на каждый push:

1. **Privacy lint** (Ubuntu) — самотест правил и проверка исходников.
2. **JarvisKit unit tests** (macOS 26) — `swift test` с предупреждениями-ошибками.
3. **App** (macOS 26) — генерация проекта, Release-сборка, размер и подпись, UI-тест.

Известное сообщение сборки: `warning: Metadata extraction skipped. No AppIntents.framework
dependency found.` — это уведомление инструмента App Intents в Xcode, а не предупреждение
компилятора; оно исчезнет, когда JARVIS получит App Intents (см. Roadmap, доп. возможности).
CI собирает последним стабильным Xcode на раннере (сейчас 26.6); сборка в Xcode 27 пока
проверяется только на твоём Mac.

Среда, в которой работает AI-ассистент разработки, — Linux без компилятора Swift, поэтому
**единственная автоматическая проверка сборки — CI на macOS**, а финальная проверка — запуск
на твоём Mac.
