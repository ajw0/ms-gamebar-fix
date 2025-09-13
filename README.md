# ms-gamebar-fix.ps1

Disable the **"We can't open this 'ms-gamebar' link"** popup after uninstalling Xbox Game Bar — or on Windows editions that never included it (e.g. Windows 11 LTSC / IoT).  
Inspired by [AveYo’s ms-gamebar-annoyance.bat](https://github.com/AveYo/Gaming/blob/main/ms-gamebar-annoyance.bat).

## Features
- Works on any modern Windows edition (including LTSC/IoT)
- Creates registry backups and a manifest before changes
- Fully restorable with `-Mode Restore`
- Supports `-DryRun` to preview changes safely
- Logs all actions and saves backups in `.\backups`

## Usage
Open **PowerShell** in the script folder and run:

```powershell
# Apply fix (most common)
.\ms-gamebar-fix.ps1 -Mode Apply

# Apply fix without waiting at the end
.\ms-gamebar-fix.ps1 -Mode Apply -NoPause

# See what WOULD change (no registry writes)
.\ms-gamebar-fix.ps1 -Mode Apply -DryRun

# Restore previous state (uses latest backup)
.\ms-gamebar-fix.ps1 -Mode Restore
Tip: If you get "script execution is disabled," enable scripts for your user:
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Revert later with:
Set-ExecutionPolicy -Scope CurrentUser Restricted
