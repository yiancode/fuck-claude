#Requires -Version 5.1
<#
.SYNOPSIS
  Apply Windows environment tweaks for https://fuck-claude.app/ scans.

.DESCRIPTION
  - Snapshots current timezone / culture / browser Preferences
  - Sets timezone to Pacific Standard Time (America/Los_Angeles) by default
  - Sets user UI language preference toward en-US when possible
  - Patches Chrome / Edge / Brave Accept-Language + DNT (+ Brave flags)

.PARAMETER DryRun
  Show actions without changing the system.

.PARAMETER Force
  Overwrite existing ~/.fuck-claude/state.json snapshot.

.PARAMETER Timezone
  Windows timezone id (tzutil). Default: Pacific Standard Time

.EXAMPLE
  .\bin\apply.ps1
  .\bin\apply.ps1 -DryRun
  .\bin\apply.ps1 -Timezone "Eastern Standard Time"
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Force,
  [string]$Timezone = $(if ($env:FUCK_CLAUDE_TIMEZONE_WIN) { $env:FUCK_CLAUDE_TIMEZONE_WIN } else { "Pacific Standard Time" })
)

$ErrorActionPreference = "Stop"
$FC_VERSION = "1.1.0"
$StateDir = Join-Path $HOME ".fuck-claude"
$StateFile = Join-Path $StateDir "state.json"
$BackupRoot = Join-Path $StateDir "backups"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$BrowsersPy = Join-Path $RepoRoot "lib\browsers.py"

function Write-Info($msg) { Write-Host "-> $msg" }
function Write-Ok($msg) { Write-Host "[OK] $msg" }
function Write-Warn($msg) { Write-Warning $msg }

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null }

Write-Host ""
Write-Host "fuck-claude apply (Windows)  v$FC_VERSION"
Write-Host "target timezone : $Timezone"
Write-Host "state file      : $StateFile"
Write-Host ""

if ($DryRun) {
  Write-Info "[dry-run] would set timezone: $Timezone"
  Write-Info "[dry-run] would prefer en-US culture"
  Write-Info "[dry-run] would patch Chrome/Edge/Brave Preferences"
  exit 0
}

if ((Test-Path $StateFile) -and -not $Force) {
  throw "state exists at $StateFile - run restore.ps1 first or pass -Force"
}

# --- Snapshot ---
Write-Info "snapshotting..."
$tzNow = (tzutil /g).Trim()
$cultureNow = [System.Globalization.CultureInfo]::CurrentCulture.Name
$uiNow = try { (Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag }) -join "," } catch { "" }

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$backupDir = Join-Path $BackupRoot $stamp
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

# Browser backup via Python if available, else pure PowerShell
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }

$profileCount = 0
if ($py) {
  & $py.Source $BrowsersPy backup $backupDir
} else {
  Write-Warn "python not found; using PowerShell browser backup"
  $local = $env:LOCALAPPDATA
  $map = @{
    chrome = Join-Path $local "Google\Chrome\User Data"
    edge   = Join-Path $local "Microsoft\Edge\User Data"
    brave  = Join-Path $local "BraveSoftware\Brave-Browser\User Data"
  }
  $manifest = @{ profiles = @(); created_at = (Get-Date).ToUniversalTime().ToString("o"); platform = "Windows" }
  foreach ($name in $map.Keys) {
    $root = $map[$name]
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem -Path $root -Directory | ForEach-Object {
      $pref = Join-Path $_.FullName "Preferences"
      if (-not (Test-Path $pref)) { return }
      if ($_.Name -match "System Profile|Guest Profile") { return }
      $dest = Join-Path (Join-Path $backupDir $name) (Join-Path $_.Name "Preferences")
      New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
      Copy-Item $pref $dest -Force
      $manifest.profiles += @{
        browser = $name
        path = $pref
        backup = $dest
      }
      $script:profileCount++
    }
  }
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $backupDir "browser-manifest.json") -Encoding UTF8
  Write-Ok "backed up $($manifest.profiles.Count) profiles (PowerShell)"
}

$state = @{
  version = $FC_VERSION
  platform = "Windows"
  created_at = (Get-Date).ToUniversalTime().ToString("o")
  snapshot_ts = $stamp
  system = @{
    timezone = $tzNow
    culture = $cultureNow
    ui_languages = $uiNow
  }
  targets = @{
    timezone = $Timezone
    culture = "en-US"
  }
  backup_dir = $backupDir
}
$state | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding UTF8
Write-Ok "snapshot saved -> $StateFile"

# --- Timezone ---
Write-Info "setting timezone to $Timezone (may need elevation)..."
try {
  tzutil /s $Timezone
  Write-Ok "timezone -> $((tzutil /g).Trim())"
} catch {
  Write-Warn "tzutil failed: $_"
  Write-Warn "Run PowerShell as Administrator, or set timezone manually."
}

# --- Culture / language (best effort, user scope) ---
Write-Info "preferring en-US language list (user)..."
try {
  $list = New-WinUserLanguageList -Language "en-US"
  Set-WinUserLanguageList -LanguageList $list -Force
  Write-Ok "WinUserLanguageList -> en-US"
} catch {
  Write-Warn "could not set WinUserLanguageList: $_"
}
try {
  Set-Culture en-US -ErrorAction SilentlyContinue
} catch { }

# --- Quit browsers ---
foreach ($p in @("chrome", "msedge", "brave")) {
  Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

# --- Patch browsers ---
Write-Info "patching browser Preferences..."
if ($py) {
  & $py.Source $BrowsersPy patch "en-US,en"
  Write-Ok "browsers patched via Python"
} else {
  $local = $env:LOCALAPPDATA
  $roots = @(
    Join-Path $local "Google\Chrome\User Data",
    Join-Path $local "Microsoft\Edge\User Data",
    Join-Path $local "BraveSoftware\Brave-Browser\User Data"
  )
  $n = 0
  foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    $isBrave = $root -match "Brave"
    Get-ChildItem $root -Directory | ForEach-Object {
      $pref = Join-Path $_.FullName "Preferences"
      if (-not (Test-Path $pref)) { return }
      if ($_.Name -match "System Profile|Guest Profile") { return }
      $json = Get-Content $pref -Raw -Encoding UTF8 | ConvertFrom-Json
      if (-not $json.intl) { $json | Add-Member -NotePropertyName intl -NotePropertyValue ([pscustomobject]@{}) }
      $json.intl | Add-Member -NotePropertyName accept_languages -NotePropertyValue "en-US,en" -Force
      $json.intl | Add-Member -NotePropertyName selected_languages -NotePropertyValue "en-US,en" -Force
      $json | Add-Member -NotePropertyName enable_do_not_track -NotePropertyValue $true -Force
      if ($isBrave) {
        if (-not $json.brave) { $json | Add-Member -NotePropertyName brave -NotePropertyValue ([pscustomobject]@{}) }
        $json.brave | Add-Member -NotePropertyName gpc_enabled -NotePropertyValue $true -Force
      }
      # ConvertTo-Json may reorder; write compact via .NET for safety is hard — use Python preferred
      $json | ConvertTo-Json -Depth 100 -Compress | Set-Content $pref -Encoding UTF8
      $n++
    }
  }
  Write-Ok "patched $n profiles (PowerShell fallback — install Python for safer JSON)"
}

# curl config for Windows curl.exe
$curlrc = Join-Path $HOME ".curlrc"
$block = @"

# added by fuck-claude apply.ps1
header = "Sec-GPC: 1"
header = "DNT: 1"
header = "Accept-Language: en-US,en;q=0.9"
"@
if (Test-Path $curlrc) {
  $c = Get-Content $curlrc -Raw
  if ($c -notmatch "Sec-GPC") { Add-Content -Path $curlrc -Value $block }
} else {
  Set-Content -Path $curlrc -Value ($block.Trim()) -Encoding UTF8
}

Write-Host ""
Write-Host "=================================================="
Write-Host " apply (Windows) complete"
Write-Host "=================================================="
Write-Host " timezone : $((tzutil /g).Trim())"
Write-Host " state    : $StateFile"
Write-Host ""
Write-Host "Next: reopen Brave/Chrome, visit https://fuck-claude.app/"
Write-Host "Restore: .\bin\restore.ps1"
Write-Host ""
Write-Warn "Chinese fonts (+17) usually remain on Windows CN systems unless fonts are removed."
Write-Host ""
