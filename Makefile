# Every target works on the dev build by default — a separate application from
# the one people install, with its own bundle identifier, config, log, hotkey and
# menu bar icon. See scripts/variant.sh and Sources/ParrotFlow/AppVariant.swift.
#
# Add VARIANT=release to act on the shipped app instead:
#
#   make run                      # build and launch ParrotFlow Dev
#   make logs                     # tail the dev log
#   VARIANT=release make logs      # tail the installed app's log
#
# `make release` always builds the release variant regardless.
export VARIANT ?= dev

V := . scripts/variant.sh &&

.PHONY: app run install uninstall stop clean reset-permissions logs \
        dev-certificate release release-certificate try-install which

## Build the app bundle into .build/
app:
	@scripts/build-app.sh

## Build and launch it (replaces the running instance of this variant only)
run: stop app
	@$(V) open ".build/$$APP_NAME.app" && echo "==> $$DISPLAY_NAME is in your menu bar."

## Copy into /Applications — permissions are far more stable there than in .build
install: app
	@$(V) rm -rf "/Applications/$$APP_NAME.app" \
	  && cp -R ".build/$$APP_NAME.app" /Applications/ \
	  && echo "==> Installed /Applications/$$APP_NAME.app"

uninstall: stop
	@$(V) rm -rf "/Applications/$$APP_NAME.app"

## Quit this variant. The other one keeps running.
stop:
	@$(V) pkill -f "$$APP_NAME.app/Contents/MacOS/$$EXECUTABLE_NAME" 2>/dev/null || true

## Print which app this variant refers to, and where its things live
which:
	@$(V) printf '  variant     %s\n  app         %s.app\n  bundle id   %s\n  config      ~/%s/config.yaml\n  log         ~/Library/Logs/%s\n' \
	  "$$VARIANT" "$$APP_NAME" "$$BUNDLE_ID" "$$CONFIG_DIR" "$$LOG_NAME"

## Create a self-signed cert so permissions survive rebuilds (asks for your password)
dev-certificate:
	@scripts/dev-certificate.sh

## Build the release artefacts into dist/ (what a user downloads)
release:
	@scripts/release.sh

## Create the certificate release builds are signed with — run once, ever
release-certificate:
	@scripts/release-certificate.sh

## Rehearse the curl install against dist/. Leaves /Applications alone, but does
## quit a running release build — the installer will not leave two of them
## fighting over the hotkey.
try-install: release
	@rm -rf /tmp/parrotflow-try && mkdir -p /tmp/parrotflow-try
	@PARROTFLOW_BASE_URL="file://$(PWD)/dist" \
	 PARROTFLOW_DEST=/tmp/parrotflow-try sh scripts/install.sh

## Forget this variant's permission grants so macOS prompts again
reset-permissions:
	@$(V) tccutil reset Microphone "$$BUNDLE_ID" || true
	@$(V) tccutil reset Accessibility "$$BUNDLE_ID" || true
	@$(V) echo "==> Permissions reset for $$BUNDLE_ID"

## Tail this variant's log
logs:
	@$(V) touch "$(HOME)/Library/Logs/$$LOG_NAME" \
	  && tail -f "$(HOME)/Library/Logs/$$LOG_NAME"

clean: stop
	@rm -rf .build dist
