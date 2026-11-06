#!/usr/bin/env bash
# Тесты для privacy-lint: каждое правило должно ловить нарушение, а чистый код — проходить.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$ROOT/scripts/privacy-lint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0

expect_violation() {
  local name="$1" code="$2"
  local dir="$WORK/$name"
  mkdir -p "$dir"
  printf '%s\n' "$code" > "$dir/Sample.swift"
  if "$LINT" "$dir" > /dev/null 2>&1; then
    echo "✗ $name: нарушение не обнаружено"
    failures=$((failures + 1))
  else
    echo "✓ $name"
  fi
}

expect_clean() {
  local name="$1" code="$2" file="${3:-Sample.swift}"
  local dir="$WORK/$name"
  mkdir -p "$(dirname "$dir/$file")"
  printf '%s\n' "$code" > "$dir/$file"
  if "$LINT" "$dir" > /dev/null 2>&1; then
    echo "✓ $name"
  else
    echo "✗ $name: ложное срабатывание"
    "$LINT" "$dir" || true
    failures=$((failures + 1))
  fi
}

expect_violation print 'func f(text: String) { print(text) }'
expect_violation debug-print 'func f(text: String) { debugPrint(text) }'
expect_violation dump 'func f(text: String) { dump(text) }'
expect_violation nslog 'func f(text: String) { NSLog("%@", text) }'
expect_violation os-logger 'let logger = Logger(subsystem: "x", category: "y")'
expect_violation os-log 'os_log("x")'
expect_violation speech 'let recognizer = SFSpeechRecognizer(locale: locale)'
expect_violation recorder 'let recorder = try AVAudioRecorder(url: url, settings: [:])'
expect_violation audio-file 'let file = try AVAudioFile(forWriting: url, settings: [:])'
expect_violation url-shared 'let task = URLSession.shared.dataTask(with: url)'
expect_violation url-default 'let config = URLSessionConfiguration.default'
expect_violation defaults 'UserDefaults.standard.set(text, forKey: "last")'
expect_violation telemetry 'import FirebaseAnalytics'
expect_violation sentry 'import Sentry'
expect_violation shell 'let path = "/bin/zsh"'
expect_violation process 'let task = Process()'

expect_clean jarvis-logger 'let log = JarvisLogger(category: "app")'
expect_clean blueprint 'func blueprint() {}; blueprint()'
expect_clean method-print 'formatter.print(value)'
expect_clean ephemeral 'let config = URLSessionConfiguration.ephemeral'
expect_clean logger-file 'private let logger = Logger(subsystem: "x", category: "y")' 'Logging/JarvisLogger.swift'
expect_clean allow-comment 'let config = URLSessionConfiguration.default // privacy-lint:allow url-cache — тестовый пример'

if [[ $failures -gt 0 ]]; then
  echo "test-privacy-lint: провалено — $failures"
  exit 1
fi
echo "test-privacy-lint: все проверки пройдены"
