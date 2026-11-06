#!/usr/bin/env bash
# Выбирает самую новую стабильную (не beta) версию Xcode на CI-раннере.
set -euo pipefail

candidates="$(ls -d /Applications/Xcode_*.app 2>/dev/null | grep -viE 'beta|release_candidate|_rc' || true)"
if [[ -z "$candidates" ]]; then
  echo "Не найдено версий Xcode_*.app, остаётся системная: $(xcode-select -p)"
  exit 0
fi

latest="$(printf '%s\n' "$candidates" | sort -V | tail -n 1)"
sudo xcode-select -s "$latest/Contents/Developer"
echo "Выбран Xcode: $latest"
