# JARVIS

[![CI](https://github.com/kornegy/JARVIS/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/kornegy/JARVIS/actions/workflows/ci.yml)

Персональный голосовой ассистент для macOS: работает в строке меню, понимает естественную
речь (русский и английский), управляет приложениями, файлами и системой — **локально,
приватно и без собственного сервера**.

> **Статус:** Phase 2 (голос). Работают «Привет, Джарвис» и Push-to-Talk, распознавание
> речи на Mac, ответы голосом с характером и текстовые команды. Сейчас JARVIS умеет
> немного: время, дата, пауза микрофона, Privacy Mode. Управление приложениями, файлами
> и системой — Phase 3 (см. [дорожную карту](docs/Roadmap.md)).

## Принципы

* **Local first** — распознавание речи, wake word, простые команды, память и настройки — на Mac.
* **Приватность по умолчанию** — голос и расшифровки не сохраняются нигде; облачный AI
  выключен и включается только с согласием; есть Privacy Mode.
* **AI предлагает, исполнитель решает** — модель возвращает план из типизированных
  инструментов; опасные действия требуют подтверждения; shell из ответа модели невозможен.
* **Лёгкость** — нативный Swift, ноль сторонних зависимостей в рантайме на текущем этапе.

## Требования

* Mac на Apple Silicon (M1 и новее) — основная цель;
* macOS 26 (Tahoe) или новее;
* для сборки: **полная Xcode 26+** (не только Command Line Tools) и
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

Если `make` пишет, что активны Command Line Tools, выберите Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Быстрый старт

```bash
git clone https://github.com/kornegy/JARVIS.git
```

```bash
cd JARVIS && make test
```

```bash
make run
```

Подробно — [docs/Development.md](docs/Development.md).

## Документация

| Документ | О чём |
|---|---|
| [Architecture.md](docs/Architecture.md) | общая схема, модули, голосовой конвейер, hybrid AI, почему нет сервера, ADR |
| [TechnologyComparison.md](docs/TechnologyComparison.md) | сравнение технологий по 10 критериям и выбор стека |
| [Security.md](docs/Security.md) | модель угроз, разрешения, подтверждения, защита от prompt injection |
| [Privacy.md](docs/Privacy.md) | что обрабатывается локально, что может уйти в сеть, гарантии и остаточные риски, чек-лист аудита |
| [Roadmap.md](docs/Roadmap.md) | фазы, MVP, риски, решения пользователя, дополнительные возможности |
| [PerformanceTargets.md](docs/PerformanceTargets.md) | цели по RAM/CPU/задержкам и методика замеров |
| [Development.md](docs/Development.md) | сборка, запуск, структура кода, как изучать модули |
| [Testing.md](docs/Testing.md) | стратегия тестирования, ручные чек-листы |
| [Release.md](docs/Release.md) | версии, подпись, нотаризация, обновления, откат |
| [CHANGELOG.md](CHANGELOG.md) | история изменений |
