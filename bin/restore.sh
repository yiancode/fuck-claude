#!/usr/bin/env bash
# restore.sh — undo changes made by fuck-claude apply.sh
#
# Restores from ~/.fuck-claude/state.json and browser Preferences backups.
#
# Usage:
#   ./bin/restore.sh
#   ./bin/restore.sh --dry-run
#   ./bin/restore.sh --keep-state   # restore but keep snapshot files
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
      sed -n '2,12p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) fc_die "unknown arg: $arg (try --help)" ;;
  esac
done

fc_require_macos
fc_require_cmds defaults python3 osascript date
fc_log_init "restore $*"

[[ -f "$FC_STATE_FILE" ]] || fc_die "no state file at $FC_STATE_FILE — nothing to restore (run apply.sh first)"

echo ""
echo "fuck-claude restore  v$FC_VERSION"
echo "state file: $FC_STATE_FILE"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  python3 - <<'PY'
import json, pathlib
state = json.loads(pathlib.Path.home().joinpath(".fuck-claude/state.json").read_text())
print("[dry-run] would restore system:")
print("  timezone:", state["system"].get("timezone"))
print("  locale  :", state["system"].get("apple_locale"))
print("  langs   :", state["system"].get("apple_languages_raw"))
print("  auto_tz :", state["system"].get("auto_timezone_active"))
print("[dry-run] would restore browser prefs from:", state.get("backup_dir"))
print("[dry-run] would restore browser policies:", list(state.get("browser_policies", {}).keys()))
PY
  exit 0
fi

# Load state into env via python
eval "$(python3 - <<'PY'
import json, pathlib, shlex
state = json.loads(pathlib.Path.home().joinpath(".fuck-claude/state.json").read_text())
sys_ = state["system"]
print(f"RESTORE_TZ={shlex.quote(sys_.get('timezone') or 'Asia/Shanghai')}")
print(f"RESTORE_LOCALE={shlex.quote(sys_.get('apple_locale') or 'zh_CN')}")
print(f"RESTORE_AUTO_TZ={shlex.quote(str(sys_.get('auto_timezone_active', '1')))}")
print(f"RESTORE_BACKUP={shlex.quote(state.get('backup_dir') or '')}")
# languages: store raw for python restore
pathlib.Path("/tmp/fuck-claude-restore-langs.txt").write_text(sys_.get("apple_languages_raw") or "", encoding="utf-8")
# policies path
pathlib.Path("/tmp/fuck-claude-restore-state.json").write_text(json.dumps(state), encoding="utf-8")
print("RESTORE_STATE_JSON=/tmp/fuck-claude-restore-state.json")
PY
)"

# ── 1) Timezone ─────────────────────────────────────────────────────────────
fc_info "restoring timezone to $RESTORE_TZ (admin password prompt)..."
ADMIN_SCRIPT="$(mktemp /tmp/fuck-claude-restore-tz.XXXXXX.sh)"
# auto tz: if original was 1/true, re-enable; else keep off
AUTO_BOOL="false"
case "$RESTORE_AUTO_TZ" in
  1|true|True|YES|yes) AUTO_BOOL="true" ;;
esac
cat >"$ADMIN_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
defaults write /Library/Preferences/com.apple.timezone.auto Active -bool $AUTO_BOOL
plutil -replace Active -bool $AUTO_BOOL /Library/Preferences/com.apple.timezone.auto.plist 2>/dev/null || true
/usr/sbin/systemsetup -settimezone "$RESTORE_TZ" || true
if [ -e "/private/var/db/timezone/zoneinfo/$RESTORE_TZ" ]; then
  ln -sfn "/private/var/db/timezone/zoneinfo/$RESTORE_TZ" /etc/localtime
elif [ -e "/var/db/timezone/zoneinfo/$RESTORE_TZ" ]; then
  ln -sfn "/var/db/timezone/zoneinfo/$RESTORE_TZ" /etc/localtime
fi
/usr/sbin/systemsetup -gettimezone
date +'%Z %z'
EOF
fc_admin "$ADMIN_SCRIPT"
rm -f "$ADMIN_SCRIPT"
fc_ok "timezone → $(fc_current_timezone) ($(fc_current_offset))"

# ── 2) Locale / languages ───────────────────────────────────────────────────
fc_info "restoring system locale / languages..."
if [[ -n "$RESTORE_LOCALE" ]]; then
  defaults write -g AppleLocale -string "$RESTORE_LOCALE"
  defaults write NSGlobalDomain AppleLocale -string "$RESTORE_LOCALE"
fi

python3 - <<'PY'
import pathlib, subprocess, re
raw = pathlib.Path("/tmp/fuck-claude-restore-langs.txt").read_text(encoding="utf-8")
# parse defaults array dump like: ( "zh-Hans-CN", "en-US" ) or plain
langs = re.findall(r'"([^"]+)"', raw)
if not langs:
    langs = [x for x in re.split(r"[\s,]+", raw.strip()) if x and x not in ("(", ")")]
if not langs:
    langs = ["zh-Hans-CN"]
cmd = ["defaults", "write", "-g", "AppleLanguages", "-array", *langs]
subprocess.check_call(cmd)
subprocess.check_call(["defaults", "write", "NSGlobalDomain", "AppleLanguages", "-array", *langs])
print("restored AppleLanguages:", langs)
PY
fc_ok "locale/languages restored"

# ── 3) Browser Preferences from backup ──────────────────────────────────────
fc_info "restoring browser Preferences from backup..."
for app in "Google Chrome" "Microsoft Edge" "Brave Browser"; do
  osascript -e "tell application \"$app\" to quit" 2>/dev/null || true
done
sleep 1

python3 - <<'PY'
import json, pathlib, shutil

state = json.loads(pathlib.Path("/tmp/fuck-claude-restore-state.json").read_text(encoding="utf-8"))
backup = pathlib.Path(state.get("backup_dir") or "")
manifest_path = backup / "browser-manifest.json"
if not manifest_path.exists():
    print("no browser-manifest.json — skip browser prefs restore")
    raise SystemExit(0)

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
n = 0
for item in manifest.get("profiles", []):
    src = pathlib.Path(item["backup"])
    dst = pathlib.Path(item["path"])
    if not src.exists():
        print("missing backup:", src)
        continue
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    n += 1
print(f"restored {n} browser profile Preferences")
PY
fc_ok "browser prefs restored from backup"

# ── 4) Browser policies ─────────────────────────────────────────────────────
fc_info "restoring browser policies..."
python3 - <<'PY'
import json, pathlib, subprocess

state = json.loads(pathlib.Path("/tmp/fuck-claude-restore-state.json").read_text(encoding="utf-8"))
policies = state.get("browser_policies") or {}

def run(cmd):
    try:
        subprocess.check_call(cmd)
        return True
    except Exception as e:
        print("  skip", cmd, e)
        return False

for domain, keys in policies.items():
    for key, val in (keys or {}).items():
        if val is None:
            # delete key we may have added
            run(["defaults", "delete", domain, key])
            continue
        # best-effort: write as string; arrays are hard — delete if looks like array dump
        if val.startswith("(") or "\n" in val:
            # original was complex (e.g. array) — delete our override so app defaults return
            run(["defaults", "delete", domain, key])
        else:
            run(["defaults", "write", domain, key, "-string", val])
print("policies restore attempted")
PY
fc_ok "browser policies restored (best-effort)"

# ── 5) curlrc note ──────────────────────────────────────────────────────────
if [[ -f "$HOME/.curlrc" ]] && grep -q 'fuck-claude' "$HOME/.curlrc" 2>/dev/null; then
  fc_warn "~/.curlrc contains fuck-claude lines — review/remove manually if desired"
fi

# ── Cleanup state ───────────────────────────────────────────────────────────
if [[ $KEEP_STATE -eq 0 ]]; then
  # archive state then remove active pointer
  ARCH="$FC_STATE_DIR/restored-$(date -u +%Y%m%dT%H%M%SZ).json"
  cp "$FC_STATE_FILE" "$ARCH"
  rm -f "$FC_STATE_FILE"
  fc_ok "moved state → $ARCH"
else
  fc_ok "kept state file (--keep-state)"
fi

rm -f /tmp/fuck-claude-restore-langs.txt /tmp/fuck-claude-restore-state.json

echo ""
echo "══════════════════════════════════════════════════"
echo " restore complete"
echo "══════════════════════════════════════════════════"
echo " timezone : $(fc_current_timezone)  offset=$(fc_current_offset)"
echo " locale   : $(defaults read -g AppleLocale 2>/dev/null || echo '?')"
echo ""
echo "Reopen browsers. Log out/in if some UI language bits stick."
echo ""
