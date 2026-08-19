<#
Automates a safe local Windows profile folder rename.

This script prepares a temporary administrator account, renames the target
profile folder while the target user is logged off, updates the profile path in
HKLM, and repairs the target user's shell-folder registry values inside
NTUSER.DAT so applications do not keep using the old profile path.

Windows still requires a second account for the actual rename because the
profile being renamed cannot be in use. The script therefore runs in:
1. Setup phase as the original account.
2. Rename phase as the temporary admin account.
3. Finalize phase as the renamed account.

The dedicated cleanup script Remove-TempAdminArtifacts.ps1 is copied to the
Public Desktop and can also be run directly from C:\Tools.

The script was developed with support for Powershell 5, since this version 
is pre-installed on many machines.
#>

[CmdletBinding()]
param(
    [string]$NewName   = '',
    [string]$OldName   = $env:UserName,
    [string]$TempAdmin = 'TempAdmin',
    [string]$ToolsRoot = ''
)

Set-StrictMode -Version Latest
$Mutex = $null

function Terminate {
    param(
        [string]$Message = '',
        [int]$Exitcode = 0
    )

    if ($Message) {
        Write-Host $Message -f Red
    }

    pause
    
    if ($Mutex) {
        $Mutex.Close()
    }
    exit $ExitCode
}

function Test-IsAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}


try {  # Pause on error


if (-not (Test-IsAdministrator)) {
    Terminate 'This script requires Administrator privileges.' -ExitCode 14
}

# Ensure only one script instance
$MutexName = 'RenameUserProfile'
$IsMutexCreated = $false

$Mutex = New-Object Threading.Mutex($false, $MutexName, [ref]$IsMutexCreated)

if (-not $IsMutexCreated) {
    Terminate 'Another instance of the script is already running!' -ExitCode 1
}

$PublicDesktop       = Join-Path $env:SystemDrive 'Users\Public\Desktop'
$PublicRenameScript  = Join-Path $PublicDesktop ($MyInvocation.MyCommand.Name)
$PublicCleanupScript = Join-Path $PublicDesktop 'Remove-TempAdminArtifacts.ps1'
$ScriptPath          = $PSCommandPath
$PowershellPath      = (Get-Process -Id $PID).Path
$TargetHiveName      = 'RenameTargetProfile'
$TargetHiveRoot      = "Registry::HKEY_USERS\$TargetHiveName"
$WinlogonPath        = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$UserSwitchPath      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\UserSwitch'
$ProfileListPath     = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

# ── Configuration ────────────────────────────────────────────────────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($ToolsRoot)) {
    try {
        $ToolsRoot = Get-ItemPropertyValue $ProfileListPath 'ToolsRoot'
    } catch {
        $ToolsRoot = Split-Path -Parent $ScriptPath
    }
}

$BackupDir           = Join-Path $ToolsRoot 'ProfileBackup'
$CleanupScriptPath   = Join-Path $ToolsRoot 'Remove-TempAdminArtifacts.ps1'
$ConfigFile          = Join-Path $env:SystemDrive 'RenameUserProfile.json'

if (Test-Path -Literal $ConfigFile) {
    $Config = [PSCustomObject](Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json)
} else {
    $Config = [PSCustomObject]@{}
}

# PowerShell 5 doesn't have .count intrinsic
$Config | Add-Member -MemberType ScriptMethod -Name IsEmpty -Value {
    $null -eq $this -or @($this.PSObject.Properties).Count -eq 0
}

# Write to json
$Config | Add-Member -MemberType ScriptMethod -Name Write -Value {
    $this | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding ASCII
}

# Safe check for property
$Config | Add-Member -MemberType ScriptMethod -Name Has -Value {
    param([string]$Name)
    [bool]$this.PSObject.Properties[$Name]
}

# Safely Add new property to the config
$Config | Add-Member -MemberType ScriptMethod -Name Add -Value {
    param(
        [string]$Name,
        [object]$Value
    )

    if ($this.PSObject.Properties[$Name]) {
        $this.$Name = $Value
    } else {
        $this | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────────────────────────

function Write-Section {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -f Cyan
}

function Create-Directory {
    param([string]$Path)
    if (-not (Test-Path -Literal $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-RegExport {
    param(
        [string]$Key,
        [string]$Destination
    )

    $null = & reg.exe export $Key $Destination /y 2>$null
    if ($LastExitCode -eq 0) {
        Write-Host "Backed up $Key to `"$Destination`"" -f DarkGray
    } else {
        Write-Host "Warning: unable to backup $Key" -f Yellow
    }
}

function Get-UserSid {
    param([string]$Name)

    try {
        return (New-Object System.Security.Principal.NTAccount($Name)).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        Write-Host "Unable to resolve SID for $Name" -f Red
        Write-Output $_
        Terminate -ExitCode 2
    }
}

function Convert-ProfilePathValue {
    param(
        [AllowNull()][string]$Value,
        [string]$SourcePath,
        [string]$DestinationPath
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $pattern = '^{0}(?=\\|$)' -f [regex]::Escape($SourcePath)
    if ($Value -imatch $pattern) {
        return [regex]::Replace($Value, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $DestinationPath
        }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    return $Value
}

function Get-RegistryValue {
    param(
        [string]$Path,
        [string]$Name
    )

    return (Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction SilentlyContinue)
}

function Update-RegistryValues {
    param(
        [string]$RegistryPath,
        [string]$SourcePath,
        [string]$DestinationPath
    )

    if (-not (Test-Path -Literal $RegistryPath)) {
        return 0
    }

    $item = Get-ItemProperty -Path $RegistryPath
    $updated = 0

    foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -in 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') {
            continue
        }

        if ($property.Value -isnot [string]) {
            continue
        }

        $newValue = Convert-ProfilePathValue `
            -Value $property.Value `
            -SourcePath $SourcePath `
            -DestinationPath $DestinationPath

        if ($newValue -ne $property.Value) {
            Set-ItemProperty `
                -Path $RegistryPath `
                -Name $property.Name `
                -Value $newValue

            $updated++
        }
    }

    return $updated
}

function Repair-ProfileRegistryPaths {
    param(
        [string]$RegistryRoot,
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $paths = @(
        (Join-Path $RegistryRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'),
        (Join-Path $RegistryRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'),
        (Join-Path $RegistryRoot 'Environment')
    )

    $total = 0
    foreach ($path in $paths) {
        $total += Update-RegistryValues `
            -RegistryPath $path `
            -SourcePath $SourcePath `
            -DestinationPath $DestinationPath
    }

    return $total
}

function Mount-TargetHive {
    param([string]$ProfileRoot)

    $ntUserPath = Join-Path $ProfileRoot 'NTUSER.DAT'
    if (-not (Test-Path -Literal $ntUserPath)) {
        Terminate "Cannot find NTUSER.DAT at `"$ntUserPath`"" -ExitCode 3
    }

    & reg.exe unload "HKU\$TargetHiveName" 2>$null | Out-Null
    & reg.exe load "HKU\$TargetHiveName" $ntUserPath | Out-Null
    if ($LastExitCode -ne 0) {
        Terminate "Failed to load target hive from `"$ntUserPath`"" -ExitCode 4
    }
}

function Dismount-TargetHive {
    & reg.exe unload "HKU\$TargetHiveName" 2>$null | Out-Null
}

function Copy-AutomationScripts {
    Create-Directory -Path $PublicDesktop

    if (-not (Test-Path -Literal $PublicRenameScript) -and (Test-Path -Literal $ScriptPath)) {
        Copy-Item -Path $ScriptPath -Destination $PublicRenameScript -Force
        Write-Host "Copied rename script to `"$PublicRenameScript`"" -f DarkGray
    }

    if (-not (Test-Path -Literal $PublicCleanupScript) -and (Test-Path -Literal $CleanupScriptPath)) {
        Copy-Item -Path $CleanupScriptPath -Destination $PublicCleanupScript -Force
        Write-Host "Copied cleanup script to `"$PublicCleanupScript`"" -f DarkGray
    }
}

function New-TempAdminAccount {
    $tempUser = Get-LocalUser -Name $TempAdmin -ErrorAction SilentlyContinue
    if ($tempUser) {
        Write-Host "Temporary account $TempAdmin already exists." -f Yellow
        return
    }

    New-LocalUser `
        -Name $TempAdmin `
        -Description 'Helper for profile rename' `
        -NoPassword -UserMayNotChangePassword |
        Out-Null

    Add-LocalGroupMember `
        -Group 'Administrators' `
        -Member $TempAdmin |
        Out-Null

    try {
        $user = [ADSI]"WinNT://./$TempAdmin,User"
        $user.PasswordExpired = 0
        $user.SetInfo()
        Write-Host "Created temporary admin $TempAdmin" -f Green
    } catch {
        Write-Host "Unable to disable password for temporary admin." -f DarkGray
        Write-Host "Please be prepared to create a password when you log into " -f Green -n
        Write-Host $TempAdmin -f Yellow
    }
}

function Disable-AutoAdminLogon {
    try {
        $Config.Add('AutoAdminLogon',    (Get-RegistryValue $WinlogonPath AutoAdminLogon))
        $Config.Add('UserSwitchEnabled', (Get-RegistryValue $UserSwitchPath Enabled))
    } catch {}
    
    Set-ItemProperty `
        -Path $WinlogonPath `
        -Name AutoAdminLogon `
        -Value '0' `
        -ErrorAction SilentlyContinue

    Set-ItemProperty `
        -Path $UserSwitchPath `
        -Name Enabled `
        -Value 1 `
        -ErrorAction SilentlyContinue
}

function Restore-AutoAdminLogon {
    if ($Config.Has('AutoAdminLogon')) {
        Set-ItemProperty `
            -Path $WinlogonPath `
            -Name AutoAdminLogon `
            -Value ([string]$Config.AutoAdminLogon) `
            -ErrorAction SilentlyContinue
    }
    if ($Config.Has('UserSwitchEnabled')) {
        Set-ItemProperty `
            -Path $UserSwitchPath `
            -Name Enabled `
            -Value ([int]$Config.UserSwitchEnabled) `
            -ErrorAction SilentlyContinue
    }
}

function Invoke-CleanupScript {
    if (-not (Test-Path -Literal $CleanupScriptPath)) {
        Write-Host "Cleanup script missing: $CleanupScriptPath" -f Yellow
        return
    }

    Write-Section "Running $TempAdmin cleanup"
    & $PowershellPath `
        -NoProfile -ExecutionPolicy Bypass `
        -File $CleanupScriptPath `
        -TempAdmin $TempAdmin
}

function Enable-AutoStartup {
    $action = New-ScheduledTaskAction `
        -Execute $PowershellPath `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PublicRenameScript`""

    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal `
        -GroupId 'INTERACTIVE' `
        -RunLevel Highest

    Register-ScheduledTask `
        -TaskName "Rename user profile" `
        -Description "Rename $OldName to $NewName" `
        -Trigger $trigger `
        -Action $action `
        -Principal $principal `
        -ErrorAction SilentlyContinue |
        Out-Null
}

function Disable-AutoStartup {
    Unregister-ScheduledTask `
        -TaskName "Rename user profile" `
        -Confirm:$false `
        -ErrorAction SilentlyContinue | 
        Out-Null
}

function Test-Confirm {
    param ([string]$Prompt = '')
    
    $Prompt = "$Prompt (Y/N)".Trim()
    
    while ($true) {
        $choice = (Read-Host $Prompt).ToUpper()
        switch ($choice) {
            "Y" { return $true }
            "N" { return $false }
            default { Write-Host 'Invalid choice' -f Red }
        }
    }
}

function Invoke-Logoff {
    if ($Mutex) {
        $Mutex.Close()
    }
        
    if (-not (Test-Confirm 'Sign out now?')) {
        exit 0
    }
    
    Write-Host "Please wait..." -f Cyan
    
    try {
        Get-CimInstance -ClassName Win32_OperatingSystem | 
            Invoke-CimMethod `
                -MethodName Win32Shutdown `
                -Arguments @{Flags = 0} |
            Out-Null
    } catch {
        try {
            Start-Process logoff.exe -Wait -ErrorAction Stop
        } catch {
            Terminate 'Please sign out manually...' -ExitCode 1
        }
    }
}

function Update-OldUserName { 
    $name = $script:OldName
    $ask  = [string]::IsNullOrWhiteSpace($name)
    
    while ($true) {
        if ($ask) {
            $name = (Read-Host 'Enter the name of the account you want to rename').Trim()
        }
        $ask = $true
        
        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Host 'Name cannot be empty' -f Red
            continue
        }
        
        if (-not (Get-LocalUser $name -ErrorAction SilentlyContinue)) {
            Write-Host 'Account ' -f Red -n
            Write-Host $name -f Yellow -n
            Write-Host ' not found' -f Red
            continue
        }
        
        $userPath = Join-Path $env:SystemDrive "Users\$name"
        if (-not (Test-Path -Literal $userPath)) {
            Write-Host "Path "                   -f Yellow  -n
            Write-Host "`"$userPath`""           -f Blue    -n
            Write-Host " not found. Rename "     -f Yellow  -n
            Write-Host "`"$($env:UserProfile)`"" -f Blue    -n
            Write-Host " instead? "              -f Yellow  -n
            
            if (Test-Confirm) {
                $script:OldPath = $env:UserProfile
            } else {
                continue
            }
            
            Write-Host 'Rename '                 -n
            Write-Host $env:UserName             -n -f Yellow
            Write-Host ' account in that case? ' -n
            
            if (Test-Confirm) {
                $script:OldName = $env:UserName
            }
            return
        }
        
        $script:OldName = $name
        $script:OldPath = $userPath
        return
    }
}

function Update-NewUserName {
    $name = $script:NewName
    $ask  = [string]::IsNullOrWhiteSpace($name)
    
    while ($true) {
        if ($ask) {
            $name = (Read-Host "Enter the desired name for $OldName").Trim()
        }
        $ask = $true
        
        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Host 'Name cannot be empty' -f Red
            continue
        }
        
        if ($name -ieq $OldName) {
            Write-Host 'The name matches the name to rename' -f Red
            continue
        }
        
        $userPath = Join-Path $env:SystemDrive "Users\$name"
        if ((Get-LocalUser $name -ErrorAction SilentlyContinue) -or (Test-Path -Literal $userPath)) {
            Write-Host 'Account ' -f Red -n
            Write-Host $name -f Yellow -n
            Write-Host ' already exists' -f Red
            continue
        }
        
        $script:NewName = $name
        $script:NewPath = $userPath
        return
    }
}

function Test-ProfileRenameComplete {
    param([string]$Sid)

    $profileImagePath = Get-RegistryValue "$ProfileListPath\$Sid" ProfileImagePath
    return ($profileImagePath -eq $NewPath) -and (Test-Path -Literal $NewPath)
}

# ── Renaming phases ──────────────────────────────────────────────────────────────────────────────────────────────────
    
Write-Host "Logged in as " -n
Write-Host $env:UserName   -f Yellow
  
if ($Config.IsEmpty()) {
    # First launch    
    Update-OldUserName
    Update-NewUserName
} else {
    if ($Config.NextLoginName -ine $env:UserName) {
        Write-Host "The previous renaming phase is incomplete! Login to " -n
        Write-Host $Config.NextLoginName -f Yellow -n
        Write-Host " account and retry."
        Terminate -ExitCode 13
    }

    # Ignore passed parameters between renaming phases
    $OldName = $Config.OldName
    $NewName = $Config.NewName
    
    $OldPath = $Config.OldPath
    $NewPath = $Config.NewPath
}

if ($Config.Has('TargetSID')) {
    $IsRenamed = Test-ProfileRenameComplete ($Config.TargetSID)
} else {
    $IsRenamed = $false
}

if ($IsRenamed -and $env:UserName -ieq $NewName) {
    Write-Section 'Phase 3 - Finalize'

    $fixedCount = Repair-ProfileRegistryPaths `
        -RegistryRoot 'HKCU:' `
        -SourcePath $OldPath `
        -DestinationPath $NewPath

    Write-Host "Final registry normalization updated $fixedCount values in HKCU." -f Green

    if (-not (Test-Path -Literal $OldPath) -and (Test-Path -Literal $NewPath)) {
        Write-Host "Profile folder already points to $NewPath" -f Green
        cmd.exe /c "mklink /J `"$OldPath`" `"$NewPath`"" 2>$null
    }

    Invoke-CleanupScript
    Restore-AutoAdminLogon

    if (Test-Path -Literal $PublicRenameScript) {
        Remove-Item -Path $PublicRenameScript -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -Literal $ConfigFile) {
        Remove-Item -Path $ConfigFile -Force -ErrorAction SilentlyContinue
    }
    
    Remove-ItemProperty -Path $ProfileListPath -Name 'ToolsRoot' -Force -ErrorAction SilentlyContinue
    
    Disable-AutoStartup
    Write-Host 'Finalize phase complete.' -f Green
    Terminate -ExitCode 0
}

if ($env:UserName -ieq $TempAdmin) {
    Write-Section 'Phase 2 - Rename'
    
    Rename-LocalUser -NewName $NewName -SID $Config.TargetSID
    Write-Host "Renamed $OldName -> $NewName." -f Green
    
    if (Test-Path -Literal $OldPath) {
        Rename-Item $OldPath $NewPath -Force
        Write-Host "Renamed `"$OldPath`" -> `"$NewPath`"." -f Green
    } elseif (Test-Path -Literal $NewPath) {
        Write-Host "Profile folder already exists at `"$NewPath`"" -f Yellow
    } else {
        Terminate "Neither `"$OldPath`" nor `"$NewPath`" exists." -ExitCode 4
    }

    Set-ItemProperty `
        -Path "$ProfileListPath\$($Config.TargetSID)" `
        -Name 'ProfileImagePath' `
        -Value $NewPath
        
    Write-Host 'Updated ProfileImagePath in HKLM ProfileList.' -f Green

    try {
        Mount-TargetHive -ProfileRoot $NewPath

        $updatedCount = Repair-ProfileRegistryPaths `
            -RegistryRoot $TargetHiveRoot `
            -SourcePath $OldPath `
            -DestinationPath $NewPath
            
        Write-Host "Normalized $updatedCount registry values inside NTUSER.DAT" -f Green
    } finally {
        Dismount-TargetHive
    }
    
    Copy-AutomationScripts

    $Config.Add('NextLoginName', $NewName)
    $Config.Write()

    Write-Host "`nRename phase complete." -f Green

    Write-Host "Next step: sign out, log back in as " -n
    Write-Host $NewName -f Yellow -n
    Write-Host " and run " -n
    Write-Host $PublicRenameScript -f Blue

    Invoke-Logoff
}

if ($env:UserName -ine $NewName) {
    Write-Section 'Phase 1 - Setup'
    Create-Directory -Path $BackupDir

    Invoke-RegExport `
        -Key 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' `
        -Destination (Join-Path $BackupDir 'ProfileList_Backup.reg')
    Invoke-RegExport `
        -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' `
        -Destination (Join-Path $BackupDir 'UserShellFolders_Backup.reg')
    Invoke-RegExport `
        -Key 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' `
        -Destination (Join-Path $BackupDir 'ShellFolders_Backup.reg')

    New-TempAdminAccount
    Disable-AutoAdminLogon
    Copy-AutomationScripts
    
    Disable-AutoStartup
    Enable-AutoStartup

    $Config.Add('TargetSID', (Get-UserSid $OldName))
    $Config.Add('OldName', $OldName)
    $Config.Add('NewName', $NewName)
    $Config.Add('OldPath', $OldPath)
    $Config.Add('NewPath', $NewPath)
    $Config.Add('NextLoginName', $TempAdmin)
    $Config.Write()
    
    Set-ItemProperty `
        -Path $ProfileListPath `
        -Name 'ToolsRoot' `
        -Value $ToolsRoot

    Write-Host "`nNext step: sign out, log in as " -n
    Write-Host $TempAdmin -f Yellow -n
    Write-Host " and run " -n
    Write-Host $PublicRenameScript -f Blue

    Invoke-Logoff
}


} catch {
    Write-Output $_
    Terminate -ExitCode 1
} finally {
    if ($Mutex) {
        $Mutex.Close()
    }
}


Write-Host "Unexpected phase! Run this script as " -f Red -n

if ($Config.Has('NextLoginName')) {
    Write-Host $Config.NextLoginName        -f Yellow -n 
    Write-Host " for the next phase."       -f Red
} else {
    Write-Host $NewName                     -f Yellow -n
    Write-Host " for setup/finalize or as " -f Red    -n
    Write-Host $TempAdmin                   -f Yellow -n
    Write-Host " for the rename phase."     -f Red
}

Terminate -ExitCode 12