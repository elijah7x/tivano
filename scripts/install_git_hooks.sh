#!/bin/bash
# Explicitly install/remove only Tivano's pre-push symlink; never change Git config.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(git rev-parse --show-toplevel)
ACTION=${1:---install}
[ "$#" -le 1 ] || { echo "Usage: scripts/install_git_hooks.sh [--install|--uninstall]" >&2; exit 2; }
case "$ACTION" in
  --install|--uninstall) ;;
  *) echo "Usage: scripts/install_git_hooks.sh [--install|--uninstall]" >&2; exit 2 ;;
esac
CONFIGURED=$(git config --get-all core.hooksPath || [ "$?" = 1 ])
if [ -n "$CONFIGURED" ]; then
  echo "core.hooksPath is already configured: $CONFIGURED. No configuration or hook was changed." >&2
  echo "Integrate $ROOT/.githooks/pre-push into that hook setup manually, preserving its existing hooks." >&2
  exit 1
fi
HOOKS=$(git rev-parse --git-path hooks)
case "$HOOKS" in /*) ;; *) HOOKS="$ROOT/$HOOKS" ;; esac
HOOK="$HOOKS/pre-push"
SOURCE="$ROOT/.githooks/pre-push"
if [ -L "$HOOK" ] && [ "$(readlink "$HOOK")" = "$SOURCE" ]; then
  if [ "$ACTION" = --uninstall ]; then
    rm "$HOOK"
    echo "Removed Tivano pre-push symlink; Git configuration and other hooks are unchanged."
  else
    echo "Tivano pre-push guard is already installed."
  fi
  exit 0
fi
if [ -e "$HOOK" ] || [ -L "$HOOK" ]; then
  echo "Existing pre-push hook at $HOOK differs; no hook was changed." >&2
  echo "Integrate $SOURCE manually into the existing hook and preserve its behavior. This installer does not overwrite hooks." >&2
  exit 1
fi
if [ "$ACTION" = --uninstall ]; then
  echo "No Tivano pre-push symlink is installed."
  exit 0
fi
[ -x "$SOURCE" ] || { echo "Tracked guard is missing or not executable: $SOURCE" >&2; exit 1; }
mkdir -p "$HOOKS"
ln -s "$SOURCE" "$HOOK"
echo "Installed Tivano pre-push guard from $ROOT. Keep this checkout available."
echo "Undo with scripts/install_git_hooks.sh --uninstall from this checkout."
