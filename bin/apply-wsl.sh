#!/usr/bin/env bash
# apply-wsl.sh - WSL-specific apply for fuck-claude.app
#
# Why WSL is special:
#   - Claude Code often runs *inside* WSL → reads Linux timezone (timedatectl)
#   - Browser scan on fuck-claude.app usually runs on *Windows* host browsers
#   - This script updates BOTH sides when possible
#
# Changes:
#   1) WSL Linux timezone  -> America/Los_Angeles (or $FUCK_CLAUDE_TIMEZONE)
#   2) Windows host timezone -> Pacific Standard Time (or $FUCK_CLAUDE_TIMEZONE_WIN)
#   3) WSL user LANG -> en_US.UTF-8
#   4) Patch Linux browsers under ~/.config (if any)
#   5) Patch Windows Chrome/Edge/Brave under /mnt/c/Users/.../AppData/Local
#
# Usage:
#   ./bin/apply-wsl.sh
#   ./bin/apply-wsl.sh --dry-run
#   ./bin/apply-wsl.sh --skip-windows-tz
#   ./bin/apply-wsl.sh --linux-browsers-only
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

DRY_RUN=0
FORCE=0
SKIP_WIN_TZ=0
LINUX_BROWSERS_ONLY=0
SKIP_WIN_BROWSERS=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --skip-windows-tz) SKIP_WIN_TZ=1 ;;
    --linux-browsers-only) LINUX_BROWSERS_ONLY=1 ;;
    --skip-windows-browsers) SKIP_WIN_BROWSERS=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: apply-wsl.sh [options]

Options:
  --dry-run                 Show plan only
  --force                   Overwrite existing ~/.fuck-claude/state.json
  --skip-windows-tz         Do not change Windows host timezone
  --skip-windows-browsers   Only patch Linux ~/.config browsers
  --linux-browsers-only     Alias of --skip-windows-browsers

Env:
  FUCK_CLAUDE_TIMEZONE          IANA zone for WSL (default America/Los_Angeles)
  FUCK_CLAUDE_TIMEZONE_WIN      Windows tzutil id (default Pacific Standard Time)
  FUCK_CLAUDE_WIN_LOCALAPPDATA  Override Windows LocalAppData path in WSL
  FUCK_CLAUDE_BROWSER_MODE      auto|both|linux|windows (default auto on WSL = both)
EOF
      exit 0
      ;;
    *) fc_die "unknown arg: $arg (try --help)" ;;
  esac
done

fc_require_wsl
fc_require_cmds python3 date
fc_log_init "apply-wsl $*"
fc_ensure_state_dir

if [[ -f "$FC_STATE_FILE" && $FORCE -eq 0 ]]; then
  fc_die "state exists at $FC_STATE_FILE — run restore first or use --force"
fi

if [[ $LINUX_BROWSERS_ONLY -eq 1 ]]; then
  SKIP_WIN_BROWSERS=1
fi

# Browser mode for lib/browsers.py
if [[ $SKIP_WIN_BROWSERS -eq 1 ]]; then
  export FUCK_CLAUDE_BROWSER_MODE=linux
else
  export FUCK_CLAUDE_BROWSER_MODE="${FUCK_CLAUDE_BROWSER_MODE:-both}"
fi

echo ""
echo "fuck-claude apply (WSL)  v${FC_VERSION}"
echo "WSL distro       : ${WSL_DISTRO_NAME:-unknown}"
echo "WSL timezone     : ${FC_TARGET_TIMEZONE}"
echo "Windows timezone : ${FC_TARGET_TIMEZONE_WIN}"
echo "browser mode     : ${FUCK_CLAUDE_BROWSER_MODE}"
echo "state file       : ${FC_STATE_FILE}"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  fc_info "[dry-run] WSL: timedatectl set-timezone ${FC_TARGET_TIMEZONE}"
  if [[ $SKIP_WIN_TZ -eq 0 ]]; then
    fc_info "[dry-run] Windows: tzutil /s \"${FC_TARGET_TIMEZONE_WIN}\""
  fi
  fc_info "[dry-run] LANG -> en_US.UTF-8 (user env)"
  fc_info "[dry-run] patch browsers mode=${FUCK_CLAUDE_BROWSER_MODE}"
  python3 "${ROOT}/lib/browsers.py" roots || true
  exit 0
fi

# --- Snapshot ---
SNAPSHOT_TS="$(date -u +%Y%m%dT%H%M%SZ)"
WSL_TZ_NOW="$(timedatectl show -p Timezone --value 2>/dev/null || readlink -f /etc/localtime 2>/dev/null || echo unknown)"
WIN_TZ_NOW=""
if fc_win_tzutil /g >/tmp/fc-win-tz.txt 2>/dev/null; then
  WIN_TZ_NOW="$(tr -d '\r' </tmp/fc-win-tz.txt | tail -n1)"
fi
LANG_NOW="${LANG:-}"

export FC_SNAPSHOT_TS="$SNAPSHOT_TS"
export FC_BACKUP_DIR FC_STATE_FILE FC_VERSION
export FC_TARGET_TIMEZONE FC_TARGET_TIMEZONE_WIN FC_TARGET_LOCALE
export FC_WSL_TZ_NOW="$WSL_TZ_NOW"
export FC_WIN_TZ_NOW="$WIN_TZ_NOW"
export FC_LANG_NOW="$LANG_NOW"
export FC_SKIP_WIN_TZ="$SKIP_WIN_TZ"
export FC_SKIP_WIN_BROWSERS="$SKIP_WIN_BROWSERS"

export PYTHONPATH="${ROOT}/lib${PYTHONPATH:+:$PYTHONPATH}"
python3 <<'PY'
import json, os, pathlib, sys
from datetime import datetime, timezone

sys.path.insert(0, os.environ.get("PYTHONPATH", "").split(":")[0])
import browsers

backup = pathlib.Path(os.path.expanduser(os.environ["FC_BACKUP_DIR"])) / os.environ["FC_SNAPSHOT_TS"]
manifest = browsers.backup_browsers(backup)

state = {
    "version": os.environ["FC_VERSION"],
    "platform": "WSL",
    "wsl_distro": os.environ.get("WSL_DISTRO_NAME", ""),
    "created_at": datetime.now(timezone.utc).isoformat(),
    "snapshot_ts": os.environ["FC_SNAPSHOT_TS"],
    "system": {
        "wsl_timezone": os.environ.get("FC_WSL_TZ_NOW", ""),
        "windows_timezone": os.environ.get("FC_WIN_TZ_NOW", ""),
        "lang": os.environ.get("FC_LANG_NOW", ""),
        "skip_windows_tz": os.environ.get("FC_SKIP_WIN_TZ", "0"),
        "skip_windows_browsers": os.environ.get("FC_SKIP_WIN_BROWSERS", "0"),
        "browser_mode": os.environ.get("FUCK_CLAUDE_BROWSER_MODE", "both"),
        "win_localappdata": str(browsers.windows_localappdata_from_wsl() or ""),
    },
    "targets": {
        "wsl_timezone": os.environ["FC_TARGET_TIMEZONE"],
        "windows_timezone": os.environ["FC_TARGET_TIMEZONE_WIN"],
        "locale": os.environ.get("FC_TARGET_LOCALE", "en_US") + ".UTF-8",
    },
    "backup_dir": str(backup),
    "user_env_file": str(pathlib.Path.home() / ".config/fuck-claude/env.sh"),
}
path = pathlib.Path(os.path.expanduser(os.environ["FC_STATE_FILE"]))
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("backed up %d browser profiles -> %s" % (len(manifest["profiles"]), backup))
print("wrote", path)
for k, v in browsers.browser_roots().items():
    print("  browser root:", k, "->", v)
PY
fc_ok "snapshot saved"

# --- 1) WSL timezone ---
fc_info "setting WSL timezone to ${FC_TARGET_TIMEZONE} (sudo may prompt)..."
if command -v timedatectl >/dev/null 2>&1; then
  if [[ "$(id -u)" -eq 0 ]]; then
    timedatectl set-timezone "$FC_TARGET_TIMEZONE"
  else
    sudo timedatectl set-timezone "$FC_TARGET_TIMEZONE"
  fi
  fc_ok "WSL timezone -> $(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
else
  fc_warn "timedatectl missing — try: sudo ln -sf /usr/share/zoneinfo/${FC_TARGET_TIMEZONE} /etc/localtime"
fi

# --- 2) Windows host timezone ---
if [[ $SKIP_WIN_TZ -eq 0 ]]; then
  fc_info "setting Windows host timezone to ${FC_TARGET_TIMEZONE_WIN}..."
  if fc_win_tzutil /s "$FC_TARGET_TIMEZONE_WIN" 2>/tmp/fc-tzutil-err.txt; then
    NOW_WIN="$(fc_win_tzutil /g 2>/dev/null | tr -d '\r' | tail -n1 || true)"
    fc_ok "Windows timezone -> ${NOW_WIN}"
  else
    fc_warn "tzutil failed (need Windows permissions?). Set host timezone manually to: ${FC_TARGET_TIMEZONE_WIN}"
    [[ -s /tmp/fc-tzutil-err.txt ]] && cat /tmp/fc-tzutil-err.txt >&2 || true
  fi
else
  fc_info "skipped Windows timezone (--skip-windows-tz)"
fi

# --- 3) WSL locale env ---
TARGET_LANG="${FC_TARGET_LOCALE}.UTF-8"
fc_info "writing WSL user locale env (${TARGET_LANG})..."
mkdir -p "${HOME}/.config/fuck-claude"
cat >"${HOME}/.config/fuck-claude/env.sh" <<EOF
# managed by fuck-claude apply-wsl
export LANG=${TARGET_LANG}
export LC_ALL=${TARGET_LANG}
export LANGUAGE=en_US:en
EOF
for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
  touch "$rc"
  if ! grep -q 'fuck-claude/env.sh' "$rc" 2>/dev/null; then
    {
      echo ""
      echo "# fuck-claude locale (WSL)"
      echo '[ -f "$HOME/.config/fuck-claude/env.sh" ] && . "$HOME/.config/fuck-claude/env.sh"'
    } >>"$rc"
  fi
done
fc_ok "user locale env ready (new shells pick it up)"

# --- 4) Browsers ---
fc_info "closing browsers if running (Windows + Linux)..."
# Linux
for b in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge brave-browser; do
  pkill -x "$b" 2>/dev/null || true
done
# Windows processes via taskkill
if command -v taskkill.exe >/dev/null 2>&1 || [[ -x /mnt/c/Windows/System32/taskkill.exe ]]; then
  TK=taskkill.exe
  [[ -x /mnt/c/Windows/System32/taskkill.exe ]] && TK=/mnt/c/Windows/System32/taskkill.exe
  for p in chrome.exe msedge.exe brave.exe; do
    "$TK" /IM "$p" /F >/dev/null 2>&1 || true
  done
fi
sleep 1

fc_info "patching browser Preferences (mode=${FUCK_CLAUDE_BROWSER_MODE})..."
python3 "${ROOT}/lib/browsers.py" patch "en-US,en"
fc_ok "browsers patched"

# curlrc inside WSL
if [[ -f "${HOME}/.curlrc" ]]; then
  if ! grep -q "Sec-GPC" "${HOME}/.curlrc" 2>/dev/null; then
    {
      echo ""
      echo "# added by fuck-claude apply-wsl"
      echo 'header = "Sec-GPC: 1"'
      echo 'header = "DNT: 1"'
      echo 'header = "Accept-Language: en-US,en;q=0.9"'
    } >>"${HOME}/.curlrc"
  fi
else
  cat >"${HOME}/.curlrc" <<'EOF'
# managed by fuck-claude apply-wsl
header = "Sec-GPC: 1"
header = "DNT: 1"
header = "Accept-Language: en-US,en;q=0.9"
EOF
fi

echo ""
echo "=================================================="
echo " apply (WSL) complete"
echo "=================================================="
echo " WSL timezone     : $(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
echo " WSL offset       : $(date +%z)"
if [[ $SKIP_WIN_TZ -eq 0 ]]; then
  echo " Windows timezone : $(fc_win_tzutil /g 2>/dev/null | tr -d '\r' | tail -n1 || echo '?')"
fi
echo " state            : ${FC_STATE_FILE}"
echo ""
echo "Next:"
echo "  1. For Claude Code in WSL: timezone above must NOT be Asia/Shanghai"
echo "  2. For fuck-claude.app: open Brave/Chrome *on Windows*, re-scan"
echo "  3. Fully quit Windows browsers before/after apply if prefs did not stick"
echo ""
echo "Restore: ./bin/restore.sh   (or ./bin/restore-wsl.sh)"
echo ""
