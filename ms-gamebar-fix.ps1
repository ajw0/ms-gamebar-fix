<#
ms-gamebar-fix.ps1
==================
Fixes the "We can't open this 'ms-gamebar' link" popup after uninstalling Xbox Game Bar on Windows 10/11.

Overview
--------
This script disables GameDVR capture flags and rewrites the per-user ms-gamebar protocol handlers to point to a benign executable (systray.exe), preventing Windows from showing the popup every time you connect a controller. It also provides a full restore mode.

Features
--------
- Works per-user, even when run elevated under a different admin account.
- Creates a full backup of affected registry keys and a JSON manifest describing pre-state.
- Restore mode re-imports backups and removes any keys that did not exist pre-Apply.
- Dry-Run mode prints what WOULD change without touching the registry.
- Self-contained: backup folders and logs are stored in `.\backups\backup-YYYY-MM-DD_HHMMSS` next to the script.
- Clear console messages and a pause at the end (optional `-NoPause` to skip).

Usage
-----
Open PowerShell in the folder containing `ms-gamebar-fix.ps1` and run:

    # Apply fix (most common):
    .\ms-gamebar-fix.ps1 -Mode Apply

    # Apply fix without waiting at the end:
    .\ms-gamebar-fix.ps1 -Mode Apply -NoPause

    # See what WOULD change (no registry writes):
    .\ms-gamebar-fix.ps1 -Mode Apply -DryRun

    # Restore previous state (uses most recent backup):
    .\ms-gamebar-fix.ps1 -Mode Restore

    # Restore from a specific backup folder:
    .\ms-gamebar-fix.ps1 -Mode Restore -BackupPath .\backups\backup-2025-09-13_170550

PowerShell Execution Policy
---------------------------
If scripts are blocked, enable them for your user with:

    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

(Run this once in a normal PowerShell window.)

To revert to the default (Restricted) later, run:

    Set-ExecutionPolicy -Scope CurrentUser Restricted

Requirements
------------
- PowerShell 5.1 or newer
- Administrator rights (UAC prompt will appear automatically)

After running in Apply mode, reconnect a controller and confirm that the popup is gone.
After Restore mode, the popup behavior should return to its original state.

#>

param(
  [ValidateSet('Apply','Restore')]
  [string]$Mode = 'Apply',

  [switch]$DryRun,
  [string]$BackupPath,

  # keep window open at the end (default). Pass -NoPause to disable.
  [switch]$NoPause,

  # internal flags (do not pass manually)
  [switch]$__Elevated,
  [string]$__OrigSid
)

function Write-Log { param([string]$Message)
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Write-Host "[$ts] $Message"
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Paths relative to this script
$ScriptDir  = Split-Path -Parent $PSCommandPath
$BackupsDir = Join-Path $ScriptDir 'backups'

function New-BackupFolder {
  if (-not (Test-Path -LiteralPath $BackupsDir)) {
    New-Item -Path $BackupsDir -ItemType Directory -Force | Out-Null
  }
  $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
  $folder = Join-Path $BackupsDir ("backup-{0}" -f $stamp)
  New-Item -Path $folder -ItemType Directory -Force | Out-Null
  return $folder
}

function Get-LatestBackupFolder {
  if (-not (Test-Path -LiteralPath $BackupsDir)) { return $null }
  $dirs = Get-ChildItem -LiteralPath $BackupsDir -Directory |
          Where-Object Name -like 'backup-*' |
          Sort-Object Name -Descending
  return $dirs | Select-Object -First 1
}

function Reg-Export { param([string]$RegPath,[string]$OutFile)
  if ($DryRun) { Write-Log "[DRY-RUN] Would export $RegPath -> $OutFile"; return $true }
  $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile)
  & reg.exe export $RegPath $OutFile /y *> $null
  if ($LASTEXITCODE -ne 0) { Write-Log "No export for $RegPath (may not exist)"; return $false }
  Write-Log "Exported $RegPath -> $OutFile"; return $true
}

function Reg-Import { param([string]$File)
  if ($DryRun) { Write-Log "[DRY-RUN] Would import $File"; return }
  if (-not (Test-Path -LiteralPath $File)) { Write-Log "Skip import: not found $File"; return }
  & reg.exe import $File *> $null
  if ($LASTEXITCODE -ne 0) { Write-Log "Failed to import $File" } else { Write-Log "Imported $File" }
}

function Set-RegistryValueIfNeeded {
  param([string]$Path,[string]$Name,$Value,[Microsoft.Win32.RegistryValueKind]$Type=[Microsoft.Win32.RegistryValueKind]::String)
  $exists = Test-Path -LiteralPath $Path
  if (-not $exists) {
    if ($DryRun) { Write-Log "[DRY-RUN] Would create key: $Path" }
    else { New-Item -Path $Path -Force | Out-Null; Write-Log "Created key: $Path" }
  }
  $current = $null; try { $current = (Get-ItemProperty -LiteralPath $Path -ErrorAction Stop).$Name } catch {}
  if ($current -ne $Value) {
    if ($DryRun) { Write-Log "[DRY-RUN] Would set $Path : $Name = $Value" }
    else { New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null; Write-Log "Set $Path : $Name = $Value" }
  } else {
    Write-Log "No change needed: $Path : $Name already '$Value'"
  }
}

function Remove-RegistryItemIfExists { param([string]$Path,[switch]$Recurse)
  if (Test-Path -LiteralPath $Path) {
    if ($DryRun) { Write-Log "[DRY-RUN] Would remove key: $Path" }
    else { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue -Recurse:$Recurse; Write-Log "Removed key: $Path" }
  } else {
    Write-Log "No change needed: key not present $Path"
  }
}

# -------------------- Capture Original User SID and Elevate --------------------
if (-not $__Elevated) {
  $origSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
  Write-Host ""
  Write-Host "Admin rights are required to edit per-user registry keys."
  Write-Host "Requesting elevation..."
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "powershell.exe"
  $argList = @(
    "-NoProfile","-ExecutionPolicy","Bypass",
    $(if (-not $NoPause) { "-NoExit" } else { "" }),
    "-File", ('"{0}"' -f $PSCommandPath),
    "-Mode", $Mode,
    "-__Elevated",
    "-__OrigSid", $origSid
  ) | Where-Object { $_ -ne "" }
  if ($DryRun)     { $argList += "-DryRun" }
  if ($BackupPath) { $argList += @("-BackupPath", ('"{0}"' -f $BackupPath)) }
  if ($NoPause)    { $argList += "-NoPause" }
  $psi.Arguments = ($argList -join ' ')
  $psi.Verb = 'runas'
  try { [Diagnostics.Process]::Start($psi) | Out-Null } catch { Write-Host "Elevation was cancelled. No changes made."; exit }
  exit
}

# In elevated instance:
if (-not $PSBoundParameters.ContainsKey('__OrigSid') -or -not $__OrigSid) {
  throw "Missing original user SID; cannot target correct registry hive."
}

$HKU          = "Registry::HKEY_USERS\$__OrigSid"
$HKU_GDVR     = Join-Path $HKU 'SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'
$HKU_GCFG     = Join-Path $HKU 'System\GameConfigStore'
$HKU_CLASSES  = Join-Path $HKU 'Software\Classes'
function C-Root ($p) { Join-Path $HKU_CLASSES $p }
function C-Cmd  ($p) { Join-Path (C-Root $p) 'shell\open\command' }

$Protocols  = @('ms-gamebar','ms-gamebarservices','ms-gamingoverlay')
$SystrayExe = "$env:SystemRoot\System32\systray.exe"

# ---------------------- Backup folder next to script ----------------------
if ($Mode -eq 'Apply') {
  if ($BackupPath) {
    if (-not (Test-Path -LiteralPath $BackupPath)) {
      if ($DryRun) { Write-Log "[DRY-RUN] Would create backup folder: $BackupPath" }
      else { New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null }
    }
    $BackupFolder = $BackupPath
  } else {
    $BackupFolder = New-BackupFolder
  }
} else {
  if ($BackupPath) {
    if (-not (Test-Path -LiteralPath $BackupPath)) { throw "BackupPath '$BackupPath' not found." }
    $BackupFolder = $BackupPath
  } else {
    $latest = Get-LatestBackupFolder
    if (-not $latest) { throw "No backups found in $BackupsDir. Provide -BackupPath." }
    $BackupFolder = $latest.FullName
  }
}

# ----------------------------- Logging -----------------------------
$LogFile = Join-Path $BackupFolder "ms-gamebar-fix.log"
if (-not $DryRun) { Start-Transcript -Path $LogFile -Append -ErrorAction SilentlyContinue | Out-Null }
Write-Log "Mode: $Mode  DryRun: $DryRun  NoPause: $NoPause"
Write-Log "Target user SID: $__OrigSid"
Write-Log "Backup folder: $BackupFolder"

# ----------------------------- Prestate -----------------------------
function Save-PreState { param([string]$Path)
  $state = [ordered]@{
    Timestamp               = (Get-Date)
    TargetSid               = $__OrigSid
    HKU_GameDVR             = (Test-Path $HKU_GDVR)
    HKU_GameConfigStore     = (Test-Path $HKU_GCFG)
    HKU_MS_gamebar          = (Test-Path (C-Root 'ms-gamebar'))
    HKU_MS_gamebarservices  = (Test-Path (C-Root 'ms-gamebarservices'))
    HKU_MS_gamingoverlay    = (Test-Path (C-Root 'ms-gamingoverlay'))
  }
  if ($DryRun) { Write-Log "[DRY-RUN] Would save prestate.json" }
  else { ($state | ConvertTo-Json -Depth 3) | Set-Content -Encoding UTF8 -LiteralPath $Path; Write-Log "Saved prestate manifest: $Path" }
}

function Load-PreState { param([string]$Path)
  if (!(Test-Path -LiteralPath $Path)) { return $null }
  try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json } catch { return $null }
}

# ----------------------------- Main Logic -----------------------------
try {
  if ($Mode -eq 'Apply') {
    $ManifestPath = Join-Path $BackupFolder 'prestate.json'
    Save-PreState -Path $ManifestPath

    Write-Host ""
    Write-Host "--- APPLYING FIX ---"
    Write-Host ""

    Write-Log "Exporting registry backups (existing keys only)..."
    Reg-Export ("HKU\{0}\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" -f $__OrigSid) (Join-Path $BackupFolder 'bk_HKU_GameDVR.reg') | Out-Null
    Reg-Export ("HKU\{0}\System\GameConfigStore" -f $__OrigSid)                           (Join-Path $BackupFolder 'bk_HKU_GameConfigStore.reg') | Out-Null
    foreach ($p in $Protocols) {
      Reg-Export ("HKU\{0}\Software\Classes\{1}" -f $__OrigSid,$p) (Join-Path $BackupFolder ("bk_HKU_Classes_{0}.reg" -f $p)) | Out-Null
    }

    Write-Log "Disabling Game DVR flags..."
    Set-RegistryValueIfNeeded $HKU_GDVR 'AppCaptureEnabled' 0 ([Microsoft.Win32.RegistryValueKind]::DWord)
    Set-RegistryValueIfNeeded $HKU_GCFG 'GameDVR_Enabled'   0 ([Microsoft.Win32.RegistryValueKind]::DWord)

    Write-Log "Configuring protocol handlers..."
    foreach ($p in $Protocols) {
      Set-RegistryValueIfNeeded (C-Root $p) '(default)'    ("URL:$p")
      Set-RegistryValueIfNeeded (C-Root $p) 'URL Protocol' ''
      Set-RegistryValueIfNeeded (C-Root $p) 'NoOpenWith'   ''
      Set-RegistryValueIfNeeded (C-Cmd  $p) '(default)'    ('"{0}"' -f $SystrayExe)
    }

    Write-Host ""
    Write-Host "OK: Fix applied."
    Write-Host "Backups and log saved in:"
    Write-Host "  $BackupFolder"
    Write-Host ""
  }
  else {
    Write-Host ""
    Write-Host "--- RESTORING FROM BACKUP ---"
    Write-Host ""

    Reg-Import (Join-Path $BackupFolder 'bk_HKU_GameDVR.reg')
    Reg-Import (Join-Path $BackupFolder 'bk_HKU_GameConfigStore.reg')
    foreach ($p in $Protocols) {
      Reg-Import (Join-Path $BackupFolder ("bk_HKU_Classes_{0}.reg" -f $p))
    }

    $ManifestPath = Join-Path $BackupFolder 'prestate.json'
    $pre = Load-PreState -Path $ManifestPath
    if ($pre -ne $null) {
      Write-Log "Pruning keys that did not exist before Apply..."
      if (-not $pre.HKU_GameDVR)            { Remove-RegistryItemIfExists $HKU_GDVR -Recurse }
      if (-not $pre.HKU_GameConfigStore)    { Remove-RegistryItemIfExists $HKU_GCFG -Recurse }
      if (-not $pre.HKU_MS_gamebar)         { Remove-RegistryItemIfExists (C-Root 'ms-gamebar') -Recurse }
      if (-not $pre.HKU_MS_gamebarservices) { Remove-RegistryItemIfExists (C-Root 'ms-gamebarservices') -Recurse }
      if (-not $pre.HKU_MS_gamingoverlay)   { Remove-RegistryItemIfExists (C-Root 'ms-gamingoverlay') -Recurse }
    } else {
      Write-Log "No prestate.json found; skipping pruning."
    }

    Write-Host ""
    Write-Host "OK: Restore completed."
    Write-Host "Restored from:"
    Write-Host "  $BackupFolder"
    Write-Host ""
  }
}
finally {
  if (-not $DryRun) { Stop-Transcript | Out-Null }
  if (-not $NoPause) { Write-Host ""; Read-Host "Press Enter to close this window" | Out-Null }
}

Write-Log "Done."
