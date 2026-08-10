#!/usr/bin/env bash
# restore.sh - OS router for fuck-claude restore
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="$(uname -s 2>/dev/null || echo unknown)"

case "$OS" in
  Darwin)
    exec "$ROOT/bin/restore-macos.sh" "$@"
    ;;
  Linux)
    exec "$ROOT/bin/restore-linux.sh" "$@"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "On Windows use: powershell -ExecutionPolicy Bypass -File bin/restore.ps1 $*" >&2
    exit 2
    ;;
  *)
    echo "Unsupported OS: $OS" >&2
    exit 2
    ;;
esac
