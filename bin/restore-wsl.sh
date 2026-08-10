#!/usr/bin/env bash
# restore-wsl.sh - undo apply-wsl.sh (WSL Linux + Windows host bits)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

DRY_RUN=0
KEEP_STATE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --keep-state) KEEP_STATE=1 ;;
    -h|--help)
      echo "Usage: restore-wsl.sh [--dry-run] [--keep-state]"
      exit 0
      ;;
    *) fc_die "unknown arg: $arg" ;;
  esac
done

fc_require_wsl
fc_require_cmds python3
fc_log_init "restore-wsl $*"

[[ -f "$FC_STATE_FILE" ]] || fc_die "no state at $FC_STATE_FILE"

echo ""
echo "fuck-claude restore (WSL)  v${FC_VERSION}"
echo "state: ${FC_STATE_FILE}"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  python3 - <<'PY'
import json, pathlib
s = json.loads(pathlib.Path.home().joinpath(".fuck-claude/state.json").read_text())
print("[dry-run] WSL tz     ->", s["system"].get("wsl_timezone"))
print("[dry-run] Windows tz ->", s["system"].get("windows_timezone"))
print("[dry-run] browsers   ->", s.get("backup_dir"))
print("[dry-run] env file   ->", s.get("user_env_file"))
PY
  exit 0
fi

eval "$(python3 - <<'PY'
import json, pathlib, shlex
s = json.loads(pathlib.Path.home().joinpath(".fuck-claude/state.json").read_text())
sys_ = s.get("system") or {}
print("RESTORE_WSL_TZ=%s" % shlex.quote(sys_.get("wsl_timezone") or "UTC"))
print("RESTORE_WIN_TZ=%s" % shlex.quote(sys_.get("windows_timezone") or ""))
print("RESTORE_BACKUP=%s" % shlex.quote(s.get("backup_dir") or ""))
print("RESTORE_ENV=%s" % shlex.quote(s.get("user_env_file") or ""))
print("SKIP_WIN_TZ_WAS=%s" % shlex.quote(str(sys_.get("skip_windows_tz", "0"))))
PY
)"

# WSL timezone
fc_info "restoring WSL timezone to ${RESTORE_WSL_TZ}..."
if command -v timedatectl >/dev/null 2>&1 && [[ -n "$RESTORE_WSL_TZ" && "$RESTORE_WSL_TZ" != "unknown" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    timedatectl set-timezone "$RESTORE_WSL_TZ" || true
  else
    sudo timedatectl set-timezone "$RESTORE_WSL_TZ" || true
  fi
  fc_ok "WSL timezone -> $(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
else
  fc_warn "could not restore WSL timezone automatically"
fi

# Windows timezone (only if we changed it)
if [[ "$SKIP_WIN_TZ_WAS" != "1" && -n "$RESTORE_WIN_TZ" ]]; then
  fc_info "restoring Windows timezone to ${RESTORE_WIN_TZ}..."
  if fc_win_tzutil /s "$RESTORE_WIN_TZ" 2>/dev/null; then
    fc_ok "Windows timezone -> $(fc_win_tzutil /g 2>/dev/null | tr -d '\r' | tail -n1)"
  else
    fc_warn "Windows tzutil restore failed — set manually: ${RESTORE_WIN_TZ}"
  fi
else
  fc_info "skip Windows timezone restore (was not changed or empty)"
fi

# env file
if [[ -n "$RESTORE_ENV" && -f "$RESTORE_ENV" ]]; then
  rm -f "$RESTORE_ENV"
  fc_ok "removed ${RESTORE_ENV}"
fi

# browsers
fc_info "restoring browser Preferences..."
for b in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge brave-browser; do
  pkill -x "$b" 2>/dev/null || true
done
if command -v taskkill.exe >/dev/null 2>&1 || [[ -x /mnt/c/Windows/System32/taskkill.exe ]]; then
  TK=taskkill.exe
  [[ -x /mnt/c/Windows/System32/taskkill.exe ]] && TK=/mnt/c/Windows/System32/taskkill.exe
  for p in chrome.exe msedge.exe brave.exe; do
    "$TK" /IM "$p" /F >/dev/null 2>&1 || true
  done
fi
sleep 1

if [[ -n "$RESTORE_BACKUP" ]]; then
  export PYTHONPATH="${ROOT}/lib${PYTHONPATH:+:$PYTHONPATH}"
  python3 "${ROOT}/lib/browsers.py" restore "$RESTORE_BACKUP"
  fc_ok "browsers restored from ${RESTORE_BACKUP}"
else
  fc_warn "no backup_dir in state"
fi

if [[ $KEEP_STATE -eq 0 ]]; then
  ARCH="${FC_STATE_DIR}/restored-$(date -u +%Y%m%dT%H%M%SZ).json"
  cp "$FC_STATE_FILE" "$ARCH"
  rm -f "$FC_STATE_FILE"
  fc_ok "archived state -> $ARCH"
fi

echo ""
echo "=================================================="
echo " restore (WSL) complete"
echo "=================================================="
echo " WSL timezone : $(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
echo "Reopen Windows browsers if you patched them."
echo ""
