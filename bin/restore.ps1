#Requires -Version 5.1
<#
.SYNOPSIS
  Restore Windows environment after fuck-claude apply.ps1

.PARAMETER DryRun
  Show planned restore actions.

.PARAMETER KeepState
  Keep state.json after restore.
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$KeepState
)

$ErrorActionPreference = "Stop"
$FC_VERSION = "1.1.0"
$StateDir = Join-Path $HOME ".fuck-claude"
$StateFile = Join-Path $StateDir "state.json"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$BrowsersPy = Join-Path $RepoRoot "lib\browsers.py"

function Write-Info($msg) { Write-Host "-> $msg" }
function Write-Ok($msg) { Write-Host "[OK] $msg" }
function Write-Warn($msg) { Write-Warning $msg }

if (-not (Test-Path $StateFile)) {
  throw "no state file at $StateFile — nothing to restore"
}

$state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host ""
Write-Host "fuck-claude restore (Windows)  v$FC_VERSION"
Write-Host "state: $StateFile"
Write-Host ""

if ($DryRun) {
  Write-Info "[dry-run] timezone -> $($state.system.timezone)"
  Write-Info "[dry-run] culture  -> $($state.system.culture)"
  Write-Info "[dry-run] browsers -> $($state.backup_dir)"
  exit 0
}

# Timezone
$tz = [string]$state.system.timezone
if ($tz) {
  Write-Info "restoring timezone to $tz ..."
  try {
    tzutil /s $tz
    Write-Ok "timezone -> $((tzutil /g).Trim())"
  } catch {
    Write-Warn "tzutil failed: $_"
  }
}

# Language list best-effort
$ui = [string]$state.system.ui_languages
if ($ui) {
  try {
    $tags = $ui.Split(",") | Where-Object { $_ }
    if ($tags.Count -gt 0) {
      $list = New-WinUserLanguageList -Language $tags[0]
      foreach ($t in $tags | Select-Object -Skip 1) {
        $list.Add($t) | Out-Null
      }
      Set-WinUserLanguageList -LanguageList $list -Force
      Write-Ok "WinUserLanguageList restored"
    }
  } catch {
    Write-Warn "language restore skipped: $_"
  }
}

# Browsers
foreach ($p in @("chrome", "msedge", "brave")) {
  Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

$backup = [string]$state.backup_dir
Write-Info "restoring browser Preferences from $backup ..."
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if ($py -and (Test-Path $BrowsersPy)) {
  & $py.Source $BrowsersPy restore $backup
  Write-Ok "browsers restored via Python"
} else {
  $manifestPath = Join-Path $backup "browser-manifest.json"
  if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $n = 0
    foreach ($item in $manifest.profiles) {
      if (Test-Path $item.backup) {
        $destDir = Split-Path $item.path
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item $item.backup $item.path -Force
        $n++
      }
    }
    Write-Ok "restored $n profiles (PowerShell)"
  } else {
    Write-Warn "no browser-manifest.json found"
  }
}

if (-not $KeepState) {
  $arch = Join-Path $StateDir ("restored-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + ".json")
  Copy-Item $StateFile $arch -Force
  Remove-Item $StateFile -Force
  Write-Ok "archived state -> $arch"
}

Write-Host ""
Write-Host "=================================================="
Write-Host " restore (Windows) complete"
Write-Host "=================================================="
Write-Host " timezone : $((tzutil /g).Trim())"
Write-Host "Reopen browsers."
Write-Host ""
