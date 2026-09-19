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

# The product name, and the one string a rename changes here.
#
# It reaches APP_NAME and DISPLAY_NAME and nothing else. BUNDLE_ID, CONFIG_DIR
# and LOG_NAME are identity: TCC keys a grant to the bundle identifier, so a
# rename that moved one would cost every existing user their permissions or
# their config. AppVariant.productName carries the same string on the Swift
# side and scripts/check-product-name.sh fails the build if they disagree.
#
# A name with a space in it works in DISPLAY_NAME and not in APP_NAME — the
# bundle would be "My App.app" and every pkill pattern and path in the Makefile
# would need quoting it does not have. Use a single word here.
PRODUCT_NAME="ParrotFlow"

VARIANT="${VARIANT:-dev}"

case "$VARIANT" in
    appstore)
        # Sandboxed, for the Mac App Store. A third application again, so it
        # can sit beside the other two while it is being worked on.
        #
        # DISPLAY_NAME, LOG_NAME and CONFIG_DIR match the release build on
        # purpose: AppVariant.swift derives them from `isDev` alone, and this
        # build is the released one as far as those are concerned. What keeps
        # them apart is the sandbox, which puts every one of them inside the
        # container — see HOME_PREFIX below.
        #
        # Both builds default to Right Command. Two of them running at once
        # both hear it; change one in its config.yaml while testing.
        APP_NAME="${PRODUCT_NAME}MAS"
        BUNDLE_ID="com.parrotflow.app.mas"
        DISPLAY_NAME="$PRODUCT_NAME"
        LOG_NAME="ParrotFlow.log"
        CONFIG_DIR=".config/parrotflow"
        ;;
    release)
        APP_NAME="$PRODUCT_NAME"
        BUNDLE_ID="com.parrotflow.app"
        DISPLAY_NAME="$PRODUCT_NAME"
        LOG_NAME="ParrotFlow.log"
        CONFIG_DIR=".config/parrotflow"
        ;;
    dev)
        APP_NAME="${PRODUCT_NAME}Dev"
        BUNDLE_ID="com.parrotflow.app.dev"
        DISPLAY_NAME="$PRODUCT_NAME Dev"
        LOG_NAME="ParrotFlow-Dev.log"
        CONFIG_DIR=".config/parrotflow-dev"
        ;;
    *)
        echo "error: VARIANT must be 'dev', 'release' or 'appstore' (got '$VARIANT')" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

# Where the app's files actually land.
#
# The sandbox rewrites the home directory, so ~/Library/Logs/ParrotFlow.log is
# not the log the App Store build writes — its own is inside the container, and
# the path you would type by hand is an empty file that exists. Everything that
# reads a path the app wrote goes through this.
if [ "$VARIANT" = "appstore" ]; then
    HOME_PREFIX="$HOME/Library/Containers/$BUNDLE_ID/Data"
else
    HOME_PREFIX="$HOME"
fi

# Not derived from PRODUCT_NAME. SwiftPM produces a binary named after the
# product in Package.swift and CFBundleExecutable has to match it, so renaming
# the app does not rename this. It is also what every `usage:` line in the
# source prints, which is why those stayed literal.
EXECUTABLE_NAME="ParrotFlow"

# LOG_NAME and CONFIG_DIR must match AppVariant.swift. The app derives them from
# its own bundle identifier at runtime; these exist so the Makefile can tail the
# right log without asking the app. HOME_PREFIX is the other half of that for
# the sandboxed variant, and it has no counterpart in the app: the app never
# sees the container path, because to it the container *is* home.
