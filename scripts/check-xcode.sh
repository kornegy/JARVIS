#!/usr/bin/env bash
# Проверяет, что для сборки выбрана полная Xcode 26+, а не Command Line Tools.
# Вызывается из Makefile перед командами, которым нужен xcodebuild или Swift Testing.

set -euo pipefail

MIN_MAJOR=26

developer_dir="$(xcode-select -p 2>/dev/null || true)"

if [[ -z "$developer_dir" || "$developer_dir" == *CommandLineTools* ]]; then
  cat >&2 <<EOF
✗ Сейчас активны Command Line Tools (${developer_dir:-ничего не выбрано}), а JARVIS собирается полной Xcode ${MIN_MAJOR}+.

  1. Установите Xcode из App Store (бесплатно), если её ещё нет:
       ls /Applications | grep -i xcode
  2. Сделайте её активной:
       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  3. Примите лицензию и установите компоненты:
       sudo xcodebuild -license accept
       xcodebuild -runFirstLaunch
  4. Повторите команду make.
EOF
  exit 1
fi

version="$(xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2 }')"
major="${version%%.*}"
if [[ -z "$major" || ! "$major" =~ ^[0-9]+$ ]]; then
  echo "✗ Не удалось определить версию Xcode в $developer_dir" >&2
  exit 1
fi
if (( major < MIN_MAJOR )); then
  echo "✗ Нужна Xcode ${MIN_MAJOR}+, сейчас выбрана $version ($developer_dir)" >&2
  exit 1
fi

echo "Xcode $version — OK"
