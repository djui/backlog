#!/usr/bin/env bash
# Builds a Release app, replaces /Applications/BackLog.app and restarts it.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build_release.sh "$@"

if pgrep -x BackLog >/dev/null; then
  osascript -e 'quit app "BackLog"' >/dev/null 2>&1 || true
  for _ in {1..50}; do
    pgrep -x BackLog >/dev/null || break
    sleep 0.1
  done
  pkill -x BackLog 2>/dev/null || true
fi

rm -rf /Applications/BackLog.app
ditto build/BackLog.app /Applications/BackLog.app
open /Applications/BackLog.app
echo "Installed /Applications/BackLog.app"
