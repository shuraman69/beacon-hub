.PHONY: install dev build package release icon uninstall clean

install:   ## собрать → поставить в /Applications → запустить
	@./scripts/install.sh

dev:       ## debug-запуск с логами в терминале
	@./scripts/dev.sh

build:     ## только собрать build/Beacon Hub.app
	@./scripts/build.sh

package:   ## universal zip в dist/ для отправки
	@./scripts/package.sh

release:   ## новая версия: CHANGELOG → тег → GitHub Release (BUMP=minor или V=1.2.3)
	@V="$(V)" BUMP="$(BUMP)" ./scripts/release.sh

icon:      ## перегенерировать иконку
	@mkdir -p .build && swiftc -O scripts/make-icon.swift -o .build/make-icon && .build/make-icon Resources/AppIcon.icns

uninstall: ## остановить и удалить из /Applications
	@pkill -x BeaconHub 2>/dev/null || true
	@rm -rf "/Applications/Beacon Hub.app"
	@echo "✓ удалено (настройки: defaults delete dev.beaconhub.app)"

clean:
	@rm -rf .build build dist
