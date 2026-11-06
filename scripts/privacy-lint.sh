#!/usr/bin/env bash
# privacy-lint: статическая проверка, что в коде JARVIS нет API, способных записать или
# отправить голос, расшифровки команд и телеметрию в обход архитектуры (docs/Privacy.md §7).
#
# Проверяются только исходники приложения и пакетов (тесты — нет).
# Исключение для конкретной строки: комментарий `privacy-lint:allow <правило> — <причина>`.
#
# Использование: scripts/privacy-lint.sh [папка ...]   (по умолчанию — App/Sources и Packages/*/Sources)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -gt 0 ]]; then
  SOURCES=("$@")
else
  SOURCES=("$ROOT/App/Sources")
  for dir in "$ROOT"/Packages/*/Sources; do
    [[ -d "$dir" ]] && SOURCES+=("$dir")
  done
fi

# Единственный файл, которому разрешено напрямую использовать os.Logger.
LOGGER_FILE='Logging/JarvisLogger.swift'

violations=0

check() {
  local rule="$1" pattern="$2" message="$3" allowed_file="${4:-}"
  local matches
  matches="$(grep -rnE --include='*.swift' -e "$pattern" "${SOURCES[@]}" 2>/dev/null \
    | grep -v "privacy-lint:allow $rule" || true)"
  if [[ -n "$allowed_file" && -n "$matches" ]]; then
    matches="$(printf '%s\n' "$matches" | grep -v "$allowed_file" || true)"
  fi
  if [[ -n "$matches" ]]; then
    echo "✗ [$rule] $message"
    printf '%s\n' "$matches" | sed 's/^/    /'
    violations=$((violations + 1))
  fi
}

check print '(^|[^A-Za-z0-9_.])(print|debugPrint|dump)\(' \
  "print/debugPrint/dump обходят privacy-safe логгер — используйте JarvisLogger"
check nslog 'NSLog\(' \
  "NSLog пишет произвольные строки в системный лог — используйте JarvisLogger"
check oslog '(os_log\(|(^|[^A-Za-z0-9_])Logger\()' \
  "os.Logger используется только внутри JarvisLogger" "$LOGGER_FILE"
check speech-server 'SFSpeechRecognizer' \
  "SFSpeechRecognizer может отправить звук на сервер — используйте SpeechAnalyzer (SpeechTranscriber/DictationTranscriber)"
check audio-to-disk '(AVAudioRecorder|AVAudioFile\(forWriting)' \
  "Запись звука на диск запрещена — аудио обрабатывается только в RAM"
check url-cache '(URLSession\.shared|URLSessionConfiguration\.default)' \
  "Используйте URLSession с ephemeral-конфигурацией (без дискового кеша и cookies)"
check user-defaults 'UserDefaults' \
  "Данные JARVIS хранятся в прозрачных файлах Application Support/JARVIS, а не в UserDefaults"
check telemetry 'import +(Firebase[A-Za-z]*|Sentry|Crashlytics|Mixpanel|Amplitude|Segment|Bugsnag|AppCenter[A-Za-z]*|Datadog[A-Za-z]*)' \
  "Сторонняя телеметрия и аналитика запрещены"
check shell '("/bin/(ba|z)?sh"|/usr/bin/env|NSTask\(|Process\(\))' \
  "Запуск shell и внешних процессов запрещён (команды модели никогда не исполняются в shell)"

if [[ $violations -gt 0 ]]; then
  echo
  echo "privacy-lint: нарушений — $violations"
  exit 1
fi

echo "privacy-lint: OK (${#SOURCES[@]} папок проверено)"
