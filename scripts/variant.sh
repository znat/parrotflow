# Resolves a build variant to its identity. Sourced, not executed.
#
#   VARIANT=dev      the build you are working on   (default)
#   VARIANT=release  the build people install
#
# The two are different applications to macOS. That is deliberate: permissions
# are granted per bundle identifier, so sharing one would mean every rebuild
# revoked the installed app's microphone access. See Sources/ParrotFlow/AppVariant.swift.
#
# The executable inside the bundle keeps its name either way — SwiftPM produces
# `ParrotFlow` and CFBundleExecutable has to match it. Only the bundle differs,
# which is also what keeps the two `pkill` patterns from matching each other.

VARIANT="${VARIANT:-dev}"

case "$VARIANT" in
    release)
        APP_NAME="ParrotFlow"
        BUNDLE_ID="com.parrotflow.app"
        DISPLAY_NAME="ParrotFlow"
        LOG_NAME="ParrotFlow.log"
        CONFIG_DIR=".config/parrotflow"
        ;;
    dev)
        APP_NAME="ParrotFlowDev"
        BUNDLE_ID="com.parrotflow.app.dev"
        DISPLAY_NAME="ParrotFlow Dev"
        LOG_NAME="ParrotFlow-Dev.log"
        CONFIG_DIR=".config/parrotflow-dev"
        ;;
    *)
        echo "error: VARIANT must be 'dev' or 'release' (got '$VARIANT')" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

EXECUTABLE_NAME="ParrotFlow"

# LOG_NAME and CONFIG_DIR must match AppVariant.swift. The app derives them from
# its own bundle identifier at runtime; these exist so the Makefile can tail the
# right log without asking the app.
