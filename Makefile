# JARVIS — основные команды разработки (см. docs/Development.md).
#
#   make test           — privacy-lint + тесты пакета JarvisKit
#   make run            — собрать Debug и запустить приложение
#   make run TEAM=XXXX  — то же, но подписать вашим сертификатом Apple Development
#   make test-ui        — UI-тесты приложения
#   make release        — Release-сборка и размер приложения
#   make run-release    — Release-сборка и запуск (для замеров CPU/памяти)

PACKAGE   := Packages/JarvisKit
PROJECT   := JARVIS.xcodeproj
SCHEME    := JARVIS
DERIVED   := build/DerivedData
DEST      := platform=macOS,arch=arm64
TEAM      ?=

ifneq ($(strip $(TEAM)),)
SIGNING := DEVELOPMENT_TEAM=$(TEAM) CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates
else
SIGNING :=
endif

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -destination '$(DEST)'

.PHONY: help check-xcode lint test test-package project build run test-ui release run-release clean

help:
	@grep -E '^#   make' Makefile | sed 's/^#   //'

check-xcode:
	@./scripts/check-xcode.sh

lint:
	./scripts/test-privacy-lint.sh
	./scripts/privacy-lint.sh

test-package: check-xcode
	swift test --package-path $(PACKAGE) -Xswiftc -warnings-as-errors

test: lint test-package

project: check-xcode
	@command -v xcodegen >/dev/null || { echo "Установите XcodeGen: brew install xcodegen"; exit 1; }
	xcodegen generate

build: project
	$(XCODEBUILD) -configuration Debug $(SIGNING) build

run: build
	open "$(DERIVED)/Build/Products/Debug/JARVIS.app"

test-ui: project
	$(XCODEBUILD) -configuration Debug $(SIGNING) test

release: project
	$(XCODEBUILD) -configuration Release $(SIGNING) build
	@du -sh "$(DERIVED)/Build/Products/Release/JARVIS.app"

# Замеры производительности — только на Release: Debug-сборка не оптимизирована.
run-release: release
	open "$(DERIVED)/Build/Products/Release/JARVIS.app"

clean:
	rm -rf build $(PROJECT) $(PACKAGE)/.build
