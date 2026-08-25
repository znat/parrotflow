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

.PHONY: app run install uninstall uninstall-dev uninstall-release stop clean \
        reset-permissions logs dev-certificate release release-certificate \
        try-install which hooks test

## Build the app bundle into .build/
app:
	@scripts/build-app.sh

## Build and launch it (replaces the running instance of this variant only)
run: stop app
	@$(V) open ".build/$$APP_NAME.app" && echo "==> $$DISPLAY_NAME is in your menu bar."

## Copy into /Applications and relaunch — permissions are far more stable
## there than in .build.
##
## Stopping first is not tidiness. Replacing the bundle under a running process
## leaves it executing an image that no longer exists: it keeps its menu bar
## icon and answers nothing, which reads as the app being broken rather than as
## the install having half happened. Relaunching after is the other half — an
## install you have to remember to follow with a launch is one you will forget.
install: stop app
	@$(V) rm -rf "/Applications/$$APP_NAME.app" \
	  && cp -R ".build/$$APP_NAME.app" /Applications/ \
	  && open "/Applications/$$APP_NAME.app" \
	  && echo "==> Installed and launched /Applications/$$APP_NAME.app"

## Quit, remove, and forget its permission grants — the things a test cycle
## needs undone together, so a stale grant or a leftover copy never survives
## into the next install. config.yaml and vocabulary.yaml are left alone: that
## is tuning, not install state.
##
## Uses VARIANT like everything else here, which defaults to dev — the one
## you are working on, running the whole time you are testing the other one.
## `make uninstall` typed without thinking wipes that one. uninstall-dev and
## uninstall-release below name the variant instead of trusting the default.
uninstall: stop reset-permissions
	@$(V) rm -rf "/Applications/$$APP_NAME.app" \
	  && echo "==> $$DISPLAY_NAME fully uninstalled — config left in ~/$$CONFIG_DIR"

## The unambiguous forms — ignore whatever VARIANT is set to.
uninstall-dev:
	@$(MAKE) --no-print-directory uninstall VARIANT=dev

uninstall-release:
	@$(MAKE) --no-print-directory uninstall VARIANT=release

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

## Every check that runs without a model, a microphone or a screen — the same
## scripts CI runs, in the same order. Keep this list and
## .github/workflows/checks.yml in step.
##
## Not here, and not skippable if you touched a prompt: check-grammar,
## check-routing and check-spelling need Ollama and gemma4:e4b, and
## check-inplace needs a real screen, the Accessibility grant and tmux. Run
## those by hand and put the numbers in the pull request.
CHECKS := numbers replacements pipeline pipeline-config wake split dotted dates \
          transform-folders eval audio-recovery possessive suggest input join \
          profiles span-rule clipboard default-config vocabulary-config learn \
          pinned-certificate no-voice

test:
	@swift build -c release
	@if command -v swiftlint >/dev/null; then \
	  swiftlint lint --quiet; \
	else \
	  echo "==> swiftlint is not installed, lint skipped"; \
	fi
	@failed=""; \
	for c in $(CHECKS); do \
	  printf '\n==> %s\n' "$$c"; \
	  scripts/check-$$c.sh || failed="$$failed $$c"; \
	done; \
	if [ -n "$$failed" ]; then printf '\nFailed:%s\n' "$$failed"; exit 1; fi; \
	printf '\nEvery check passed.\n'

## Point git at .githooks, so commit subjects are checked before they land.
## Once per clone: hooks are not cloned with the repository.
hooks:
	@git config core.hooksPath .githooks
	@echo "==> Commit subjects are now checked against Conventional Commits."

.PHONY: repo-settings

## Compare GitHub's own settings for the repository with settings/repo.yml.
## Reads only. Writing them is `scripts/repo-settings.sh --apply`, kept out of
## here on purpose: a target that changes the live repository is one you can
## run by mistake.
repo-settings:
	@scripts/repo-settings.sh

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
	@$(V) tccutil reset ListenEvent "$$BUNDLE_ID" || true
	@$(V) echo "==> Permissions reset for $$BUNDLE_ID"

## Tail this variant's log
logs:
	@$(V) touch "$(HOME)/Library/Logs/$$LOG_NAME" \
	  && tail -f "$(HOME)/Library/Logs/$$LOG_NAME"

clean: stop
	@rm -rf .build dist
