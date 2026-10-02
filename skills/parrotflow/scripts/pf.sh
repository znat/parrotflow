#!/usr/bin/env bash
# Finds ParrotFlow on this Mac and prints what an agent needs, one key=value per line.
#
#   bash pf.sh        the release app, ~/.config/parrotflow
#   bash pf.sh dev    the dev app, ~/.config/parrotflow-dev
#
# PARROTFLOW_CONFIG_DIR picks the config directory, as it does for the app.
# PARROTFLOW_BIN picks the binary; used by the repository's checks.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_md="$here/../SKILL.md"

variant=release
[ "${1:-}" = dev ] && variant=dev
case "${PARROTFLOW_CONFIG_DIR:-}" in
  "$HOME/.config/parrotflow-dev" | "$HOME/.config/parrotflow-dev/") variant=dev ;;
esac

if [ "$variant" = dev ]; then
  bundle=ParrotFlowDev; other=ParrotFlow; default_dir="$HOME/.config/parrotflow-dev"
else
  bundle=ParrotFlow; other=ParrotFlowDev; default_dir="$HOME/.config/parrotflow"
fi

find_app() {
  local dir
  for dir in /Applications "$HOME/Applications"; do
    if [ -x "$dir/$1.app/Contents/MacOS/ParrotFlow" ]; then
      echo "$dir/$1.app"
      return
    fi
  done
}

# True when $1 >= $2, comparing dotted numbers.
version_ge() {
  local IFS=. i
  local -a a=($1) b=($2)
  for i in 0 1 2; do
    [ "${a[i]:-0}" -gt "${b[i]:-0}" ] && return 0
    [ "${a[i]:-0}" -lt "${b[i]:-0}" ] && return 1
  done
  return 0
}

binary="${PARROTFLOW_BIN:-}"
if [ -z "$binary" ]; then
  app="$(find_app "$bundle")"
  [ -n "$app" ] && binary="$app/Contents/MacOS/ParrotFlow"
else
  case "$binary" in
    *.app/Contents/MacOS/*) app="${binary%/Contents/MacOS/*}" ;;
    *) app="" ;;
  esac
fi

echo "variant=$variant"
if [ -z "$binary" ] || [ ! -x "$binary" ]; then
  echo "binary="
  echo "error=$bundle.app is not in /Applications or ~/Applications"
  echo "install=brew install znat/tap/parrotflow"
  found_other="$(find_app "$other")"
  [ -n "$found_other" ] && echo "other_app=$found_other"
  exit 1
fi

config_dir="${PARROTFLOW_CONFIG_DIR:-$default_dir}"
config_dir="${config_dir%/}"
contents="$(cd "$(dirname "$binary")/.." && pwd)"
plist="$contents/Info.plist"

app_version=unknown
if [ -f "$plist" ]; then
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || echo unknown)"
fi
skill_version="$(sed -n 's/^ *app_version: *["'\'']\{0,1\}\([0-9][0-9.]*\).*/\1/p' "$skill_md" 2>/dev/null | head -1)"
[ -n "$skill_version" ] || skill_version=unknown

echo "app=${app:-}"
echo "binary=$binary"
echo "config_dir=$config_dir"
echo "config=$config_dir/config.yaml"
[ -f "$contents/Resources/config.example.yaml" ] && echo "config_example=$contents/Resources/config.example.yaml"
echo "built_in=$config_dir/transforms/built-in"
echo "app_version=$app_version"
echo "skill_version=$skill_version"

if [ "$app_version" = unknown ] || [ "$skill_version" = unknown ]; then
  echo "version_match=unknown"
elif [ "$app_version" = "$skill_version" ]; then
  echo "version_match=yes"
else
  echo "version_match=no"
  echo "reinstall=npx skills add 'znat/parrotflow#v$app_version@parrotflow'"
  if ! version_ge "$app_version" "$skill_version"; then
    echo "update_app=ParrotFlow menu → Check for Updates, or: brew upgrade --greedy znat/tap/parrotflow"
  fi
fi

# --schema came after 0.15.0. An older binary reads the config to reject the
# flag, and before 0.12.0 it started a second copy of the app instead. A dev
# build keeps the last release's number, so it is asked from 0.12.0 on.
schema=no
probe=no
if [ "$app_version" = unknown ] || ! version_ge 0.15.0 "$app_version"; then
  probe=yes
elif [ "$variant" = dev ] && version_ge "$app_version" 0.12.0; then
  probe=yes
fi
if [ "$probe" = yes ]; then
  if PARROTFLOW_CONFIG_DIR="$config_dir" "$binary" --schema < /dev/null > /dev/null 2>&1; then
    schema=yes
  fi
fi
echo "schema=$schema"

found_other="$(find_app "$other")"
[ -n "$found_other" ] && echo "other_app=$found_other"
exit 0
