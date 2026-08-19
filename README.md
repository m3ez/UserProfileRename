This folder contains PowerShell automation for renaming a local Windows user profile folder and cleaning up the temporary administrator account used during the process.

## Scripts

- [Rename-UserProfile.ps1](Rename-UserProfile.ps1)
  Three-phase workflow for preparing the rename, performing the folder rename from a temporary admin account, and finalizing the renamed profile.
- [Remove-TempAdminArtifacts.ps1](Remove-TempAdminArtifacts.ps1)
  Cleanup script for removing the temporary admin account, its profile data, and common registry leftovers such as `ProfileList`, Group Policy cache, and Windows Search references.
- `ProfileBackup\`
  Backup directory created by the scripts during execution.

## Registry fixes

Renaming updates `ProfileImagePath` and fixes references to the profile path, which often cause installers to fail after a manual rename:    

- `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\<SID>`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders`
- Equivalent values in the `NTUSER.DAT` file of the target profile when the profile is offline

This fixes stale paths like `C:\Users\oldname\AppData\Roaming`.

## Requirements

- Run from an elevated PowerShell window (Adminstrator privileges)
- Use only inside local user account
- The target user must be able to sign out completely
- Keep a recovery path available before changing the profile folder

## Standard workflow

Run the script from the context menu, via `PowerShell`, or via `pwsh`. After each phase is complete, you will be prompted to log out of the account and log in to another one. Log in to the specified account and **wait for the script to run automatically** (it is automatically added to Task Scheduler). If the script does not start on its own, run it from the desktop (it will be copied there automatically). **The script may require your attention in some cases!** However, it does not require any confirmation if there are no errors.

You can run the script without any parameters:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\UserProfileRename\Rename-UserProfile.ps1
```

In that case, you'll need to enter the target name in the terminal. By default, the script renames the current account.

You can also pass the necessary parameters when running the script:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\UserProfileRename\Rename-UserProfile.ps1 `
  -OldName $env:UserName `
  -NewName 'MyName' `
  -TempAdmin 'TempAdmin' `
  -ToolsRoot 'C:\Tools'
```

| Parameter | Description                                                      | Requirements                                                               |
| --------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------- |
| OldName   | The name of the account that needs to be renamed                 | - Does not match the target name                                           |
| NewName   | The target name that the account will be given                   | - Does not match the old name <br/>- Does not match the existing name      |
| TempAdmin | The name of the temporary account from which Phase 2 is executed | - Does not match the existing name<br/>- Can be created without a password |
| ToolsRoot | Directory containing scripts, backups, and support files         | - Available for read and write access during all renaming phases           |

The passed parameters are stored in `RenameUserProfile.json` file in `$ToolsRoot` and will be used until all renaming phases are complete. Any parameters passed after Phase 1 will be ignored to ensure reliable renaming process. They will be read from `.json`.

### Phase 1: setup from current user

What it does:

- Validates administrator access
- Creates backups under `ProfileBackup\`
- Validates passed parameters, saves them to `ProfileBackup\RenameUserProfile.json`
- Creates the temporary admin account without password
- Copies the automation scripts to `C:\Users\Public\Desktop`
- Prepares Windows to show account selection on next sign-in
- Creates a task to automatically run the script at login

Requests automatic sign out.

### Phase 2: rename from TempAdmin

Sign in as `$TempAdmin` (selected temprorary name; default is `TempAdmin`).

What it does:

- Renames `C:\Users\$OldName` to `C:\Users\$NewName`
- Updates `ProfileImagePath` to `C:\Users\$NewName` 
- Loads the renamed profile's `NTUSER.DAT`
- Repairs stale shell-folder and environment values while the original profile is offline

Then sign out again.

### Phase 3: finalize as the renamed user

Sign in as the renamed user.

What it does:

- Re-checks the rename state
- Creates system link `C:\Users\$OldName` -> `C:\Users\$NewName`
- Normalizes the current user's `HKCU` profile-path registry values
- Restores the original logon-related registry settings
- Launches [Remove-TempAdminArtifacts.ps1](Remove-TempAdminArtifacts.ps1)
- Removes `ProfileBackup\RenameUserProfile.json`
- Removes scheduled task (script autostartup)

### Cleanup script

If you need to [run cleanup](Remove-TempAdminArtifacts.ps1) separately:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\UserProfileRename\Remove-TempAdminArtifacts.ps1 `
  -TempAdmin 'TempAdmin'
```

Run it from an elevated PowerShell window while logged in as the renamed user,
not as `TempAdmin`.

## Verification

After the workflow finishes, validate:

```powershell
whoami
echo $env:UserProfile
echo $env:AppData
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
reg query HKLM\SOFTWARE /f TempAdmin /s
Get-CimInstance Win32_UserProfile | where { $_.LocalPath -like '*TempAdmin*' }
```

Expected outcome:

- `UserProfile`, `AppData`, and `Shell Folders` point to the new path
- no `TempAdmin` profile remains
- no `TempAdmin` registry references remain, or only protected system-generated
  entries that require separate elevated cleanup
