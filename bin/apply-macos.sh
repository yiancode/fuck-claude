#!/usr/bin/env bash
# apply.sh - reshape macOS + Chromium browsers for a greener fuck-claude.app scan.
#
# What it changes:
#   1) System timezone -> America/Los_Angeles (or $FUCK_CLAUDE_TIMEZONE)
#   2) Disable automatic timezone
#   3) System locale / preferred languages -> en_US / en-US
#   4) Chrome / Edge / Brave Accept-Language -> English only
#   5) Enable DNT + GPC-related flags where possible
#   6) Brave fingerprinting policy -> Strict
#
# What it does NOT change:
#   - System Chinese fonts (macOS system fonts; risky to remove)
#   - Network / VPN / IP geolocation
#   - Claude Code binary itself
#
# Usage:
#   ./bin/apply.sh
#   ./bin/apply.sh --dry-run
#   FUCK_CLAUDE_TIMEZONE=America/New_York ./bin/apply.sh
#   ./bin/apply.sh --force
#
# State is saved to ~/.fuck-claude/state.json for ./bin/restore.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) fc_die "unknown arg: $arg (try --help)" ;;
  esac
done

fc_require_macos
fc_require_cmds defaults python3 osascript date
fc_log_init "apply $*"
fc_ensure_state_dir

if [[ -f "$FC_STATE_FILE" && $FORCE -eq 0 ]]; then
  fc_warn "state already exists at $FC_STATE_FILE"
  fc_warn "run restore.sh first, or re-run with --force to overwrite snapshot"
  fc_die "refusing to overwrite existing snapshot (use --force)"
fi

echo ""
echo "fuck-claude apply  v${FC_VERSION}"
echo "target timezone : ${FC_TARGET_TIMEZONE}"
echo "target locale   : ${FC_TARGET_LOCALE}"
echo "target languages: ${FC_TARGET_LANGS}"
echo "state file      : ${FC_STATE_FILE}"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  fc_info "[dry-run] would snapshot current env -> ${FC_STATE_FILE}"
  fc_info "[dry-run] would set timezone ${FC_TARGET_TIMEZONE} (admin)"
  fc_info "[dry-run] would set AppleLocale=${FC_TARGET_LOCALE} AppleLanguages=${FC_TARGET_LANGS}"
  fc_info "[dry-run] would patch Chrome/Edge/Brave languages + DNT + Brave GPC/FP"
  exit 0
fi

# --- 1) Snapshot current state ------------------------------------------------
fc_info "snapshotting current environment..."

SNAPSHOT_TS="$(date -u +%Y%m%dT%H%M%SZ)"
export FC_SNAPSHOT_TS="$SNAPSHOT_TS"
export FC_BACKUP_DIR
export FC_STATE_FILE
export FC_VERSION
export FC_TARGET_TIMEZONE
export FC_TARGET_LOCALE
export FC_TARGET_LANGS

export FC_TZ_NOW
FC_TZ_NOW="$(fc_current_timezone)"
export FC_LOCALE_NOW
FC_LOCALE_NOW="$(defaults read -g AppleLocale 2>/dev/null || echo "")"
export FC_LANGS_NOW
FC_LANGS_NOW="$(defaults read -g AppleLanguages 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' || echo "")"
export FC_AUTO_TZ_NOW
FC_AUTO_TZ_NOW="$(defaults read /Library/Preferences/com.apple.timezone.auto Active 2>/dev/null || echo "unknown")"

python3 <<'PY'
import json, os, pathlib, shutil, subprocess
from datetime import datetime, timezone

backup_root = pathlib.Path(os.environ["FC_BACKUP_DIR"]) / os.environ["FC_SNAPSHOT_TS"]
backup_root.mkdir(parents=True, exist_ok=True)
homes = pathlib.Path.home()
browsers = {
    "chrome": homes / "Library/Application Support/Google/Chrome",
    "edge": homes / "Library/Application Support/Microsoft Edge",
    "brave": homes / "Library/Application Support/BraveSoftware/Brave-Browser",
}
manifest = {"profiles": [], "created_at": datetime.now(timezone.utc).isoformat()}
for name, root in browsers.items():
    if not root.exists():
        continue
    for pref in root.glob("*/Preferences"):
        rel = pref.relative_to(root)
        if any(x in str(rel) for x in ("System Profile", "Guest Profile")):
            continue
        dest = backup_root / name / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(pref, dest)
        try:
            data = json.loads(pref.read_text(encoding="utf-8"))
        except Exception:
            data = {}
        intl = data.get("intl", {})
        manifest["profiles"].append({
            "browser": name,
            "path": str(pref),
            "backup": str(dest),
            "accept_languages": intl.get("accept_languages"),
            "selected_languages": intl.get("selected_languages"),
            "enable_do_not_track": data.get("enable_do_not_track"),
        })
(backup_root / "browser-manifest.json").write_text(
    json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
)
print("backed up %d browser profile prefs -> %s" % (len(manifest["profiles"]), backup_root))

def defaults_read(domain, key):
    try:
        return subprocess.check_output(["defaults", "read", domain, key], text=True).strip()
    except Exception:
        return None

state = {
    "version": os.environ["FC_VERSION"],
    "created_at": datetime.now(timezone.utc).isoformat(),
    "snapshot_ts": os.environ["FC_SNAPSHOT_TS"],
    "system": {
        "timezone": os.environ.get("FC_TZ_NOW", ""),
        "apple_locale": os.environ.get("FC_LOCALE_NOW", ""),
        "apple_languages_raw": os.environ.get("FC_LANGS_NOW", ""),
        "auto_timezone_active": os.environ.get("FC_AUTO_TZ_NOW", "unknown"),
    },
    "targets": {
        "timezone": os.environ["FC_TARGET_TIMEZONE"],
        "locale": os.environ["FC_TARGET_LOCALE"],
        "languages": os.environ["FC_TARGET_LANGS"],
    },
    "backup_dir": str(backup_root),
    "browser_policies": {},
}
for domain, keys in {
    "com.google.Chrome": ["ApplicationLocaleValue", "ExtensionInstallForcelist"],
    "com.microsoft.Edge": ["ApplicationLocaleValue", "ExtensionInstallForcelist"],
    "com.brave.Browser": [
        "ApplicationLocaleValue",
        "DefaultFingerprintingBlocking",
        "GlobalPrivacyControlEnabled",
        "DefaultAdBlockSetting",
    ],
}.items():
    state["browser_policies"][domain] = {k: defaults_read(domain, k) for k in keys}

path = pathlib.Path(os.environ["FC_STATE_FILE"])
path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("wrote", path)
PY
fc_ok "snapshot saved"

# --- 2) System timezone (admin) ----------------------------------------------
fc_info "setting timezone to ${FC_TARGET_TIMEZONE} (admin password prompt)..."
ADMIN_SCRIPT="$(mktemp /tmp/fuck-claude-tz.XXXXXX.sh)"
cat >"$ADMIN_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
defaults write /Library/Preferences/com.apple.timezone.auto Active -bool false
plutil -replace Active -bool false /Library/Preferences/com.apple.timezone.auto.plist 2>/dev/null || true
defaults write /Library/Preferences/com.apple.preferences.timezone.auto Active -bool false 2>/dev/null || true
/usr/sbin/systemsetup -settimezone "${FC_TARGET_TIMEZONE}"
if [ -e "/private/var/db/timezone/zoneinfo/${FC_TARGET_TIMEZONE}" ]; then
  ln -sfn "/private/var/db/timezone/zoneinfo/${FC_TARGET_TIMEZONE}" /etc/localtime
elif [ -e "/var/db/timezone/zoneinfo/${FC_TARGET_TIMEZONE}" ]; then
  ln -sfn "/var/db/timezone/zoneinfo/${FC_TARGET_TIMEZONE}" /etc/localtime
fi
/usr/sbin/systemsetup -gettimezone
date +"%Z %z"
EOF
fc_admin "$ADMIN_SCRIPT"
rm -f "$ADMIN_SCRIPT"
fc_ok "timezone -> $(fc_current_timezone) ($(fc_current_offset))"

# --- 3) System locale / languages --------------------------------------------
fc_info "setting system locale / languages..."
defaults write -g AppleLocale -string "$FC_TARGET_LOCALE"
defaults write NSGlobalDomain AppleLocale -string "$FC_TARGET_LOCALE"
IFS=',' read -r -a _langs <<<"$FC_TARGET_LANGS"
defaults write -g AppleLanguages -array "${_langs[@]}"
defaults write NSGlobalDomain AppleLanguages -array "${_langs[@]}"
fc_ok "AppleLocale=${FC_TARGET_LOCALE}  AppleLanguages=${_langs[*]}"

# --- 4) Patch Chromium browsers ----------------------------------------------
fc_info "patching Chrome / Edge / Brave preferences..."
for app in "Google Chrome" "Microsoft Edge" "Brave Browser"; do
  osascript -e "tell application \"${app}\" to quit" 2>/dev/null || true
done
sleep 1

python3 <<'PY'
import json, pathlib

LANG = "en-US,en"
FORCED = ["en-US", "en"]
browsers = [
    pathlib.Path.home() / "Library/Application Support/Google/Chrome",
    pathlib.Path.home() / "Library/Application Support/Microsoft Edge",
    pathlib.Path.home() / "Library/Application Support/BraveSoftware/Brave-Browser",
]
n = 0
for root in browsers:
    if not root.exists():
        continue
    is_brave = "Brave" in str(root)
    for pref in root.glob("*/Preferences"):
        if any(x in str(pref) for x in ("System Profile", "Guest Profile")):
            continue
        try:
            data = json.loads(pref.read_text(encoding="utf-8"))
        except Exception as e:
            print("skip", pref, e)
            continue
        intl = data.setdefault("intl", {})
        intl["accept_languages"] = LANG
        intl["selected_languages"] = LANG
        intl["forced_languages"] = FORCED
        data["enable_do_not_track"] = True
        sc = data.setdefault("spellcheck", {})
        sc["dictionaries"] = ["en-US"]
        sc["dictionary"] = "en-US"
        if is_brave:
            brave = data.setdefault("brave", {})
            brave["gpc_enabled"] = True
            brave["fingerprinting_block_mode"] = 2
            dcsv = data.setdefault("profile", {}).setdefault("default_content_setting_values", {})
            dcsv["brave_fingerprinting"] = 2
            dcsv["brave_fingerprinting_v2"] = 2
        profile = data.setdefault("profile", {})
        if profile.get("exit_type") == "Crashed":
            profile["exit_type"] = "Normal"
        pref.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
        n += 1
print("patched %d browser profiles" % n)
PY

defaults write com.google.Chrome ApplicationLocaleValue -string "en-US" 2>/dev/null || true
defaults write com.microsoft.Edge ApplicationLocaleValue -string "en-US" 2>/dev/null || true
defaults write com.brave.Browser ApplicationLocaleValue -string "en-US" 2>/dev/null || true
defaults write com.brave.Browser DefaultFingerprintingBlocking -int 2 2>/dev/null || true
defaults write com.brave.Browser GlobalPrivacyControlEnabled -bool true 2>/dev/null || true

GPC_ID="niiahgnkkalkindhghjcaojcpbkhfbbp"
UPDATE_URL="https://clients2.google.com/service/update2/crx"
defaults write com.google.Chrome ExtensionInstallForcelist -array "${GPC_ID};${UPDATE_URL}" 2>/dev/null || true
defaults write com.microsoft.Edge ExtensionInstallForcelist -array "${GPC_ID};${UPDATE_URL}" 2>/dev/null || true

fc_ok "browser prefs + policies updated"

# --- 5) curl helpers ---------------------------------------------------------
if [[ -f "${HOME}/.curlrc" ]]; then
  if ! grep -q "Sec-GPC" "${HOME}/.curlrc" 2>/dev/null; then
    {
      echo ""
      echo "# added by fuck-claude apply"
      echo "header = \"Sec-GPC: 1\""
      echo "header = \"DNT: 1\""
      echo "header = \"Accept-Language: en-US,en;q=0.9\""
    } >>"${HOME}/.curlrc"
    fc_ok "appended GPC/DNT/Accept-Language to ~/.curlrc"
  fi
else
  cat >"${HOME}/.curlrc" <<'EOF'
# managed by fuck-claude apply
header = "Sec-GPC: 1"
header = "DNT: 1"
header = "Accept-Language: en-US,en;q=0.9"
EOF
  fc_ok "created ~/.curlrc"
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "=================================================="
echo " apply complete"
echo "=================================================="
echo " timezone : $(fc_current_timezone)  offset=$(fc_current_offset)"
echo " locale   : $(defaults read -g AppleLocale 2>/dev/null || echo "?")"
echo " languages: $(defaults read -g AppleLanguages 2>/dev/null | tr -d "\n" || echo "?")"
echo " state    : ${FC_STATE_FILE}"
echo ""
echo "Next:"
echo "  1. Fully quit and reopen browsers (Brave recommended)"
echo "  2. Open https://fuck-claude.app/ and re-scan"
echo "  3. Expect CLEAR if timezone stays non-China"
echo "  4. Chinese fonts (+17) on macOS often remain (system fonts)"
echo ""
echo "Restore later:"
echo "  ./bin/restore.sh"
echo ""
fc_warn "If timezone flips back to Asia/Shanghai, disable:"
fc_warn "  System Settings -> Date & Time -> Set time zone automatically"
echo ""
