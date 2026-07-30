APP_NAME   := ParrotFlow
BUNDLE_ID  := com.parrotflow.app
APP        := .build/$(APP_NAME).app

.PHONY: app run install uninstall stop clean reset-permissions logs dev-certificate

## Build ParrotFlow.app into .build/
app:
	@scripts/build-app.sh

## Build and launch (replaces any running instance)
run: stop app
	@open "$(APP)"
	@echo "==> ParrotFlow is in your menu bar."

## Copy the app into /Applications
install: app
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP)" /Applications/
	@echo "==> Installed to /Applications/$(APP_NAME).app"

uninstall: stop
	@rm -rf "/Applications/$(APP_NAME).app"

## Quit any running instance
stop:
	@pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true

## Create a self-signed cert so permissions survive rebuilds (asks for your password)
dev-certificate:
	@scripts/dev-certificate.sh

## Forget the microphone grant so macOS prompts again
reset-permissions:
	@tccutil reset Microphone $(BUNDLE_ID) || true
	@tccutil reset Accessibility $(BUNDLE_ID) || true
	@echo "==> Permissions reset for $(BUNDLE_ID)"

## Tail the app's log
logs:
	@touch "$(HOME)/Library/Logs/$(APP_NAME).log"
	@tail -f "$(HOME)/Library/Logs/$(APP_NAME).log"

clean: stop
	@rm -rf .build
