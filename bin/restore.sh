#!/usr/bin/env bash
# restore.sh - OS router for fuck-claude restore (macOS / Linux / WSL)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
OS="$(uname -s 2>/dev/null || echo unknown)"

case "$OS" in
  Darwin)
    exec "$ROOT/bin/restore-macos.sh" "$@"
    ;;
  Linux)
    if fc_is_wsl; then
      exec "$ROOT/bin/restore-wsl.sh" "$@"
    fi
    exec "$ROOT/bin/restore-linux.sh" "$@"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "On native Windows use: powershell -ExecutionPolicy Bypass -File bin/restore.ps1 $*" >&2
    echo "Inside WSL use:        ./bin/restore.sh" >&2
    exit 2
    ;;
  *)
    echo "Unsupported OS: $OS" >&2
    exit 2
    ;;
esac
