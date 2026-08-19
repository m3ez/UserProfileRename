<#
Removes a temporary administrator account and its common registry remnants.

Use this script after Rename-UserProfile.ps1 has completed and the renamed
account can sign in normally. The script removes the TempAdmin local account,
its Win32_UserProfile entry, leftover profile registry keys, Group Policy
cache, and Windows Search leaf keys that still point to the temporary profile.
#>

[CmdletBinding()]
param(
    [string]$TempAdmin = 'TempAdmin',
    [string]$BackupRoot = ''
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
    
    if ($script:Mutex) {
        $script:Mutex.Close()
    }
    exit $ExitCode
}

function Test-IsAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}


try {  # Pause on error


if (-not (Test-IsAdministrator)) {
    Terminate 'This cleanup script requires Administrator privileges.' -Exitcode 1
}

if ($env:UserName -ieq $TempAdmin) {
    Terminate "You cannot delete the data of the temporary account $TempAdmin from which you are logged in!" -Exitcode 1
}


# Ensure only one script instance
$MutexName = 'CleanupTempAdmin'
$IsMutexCreated = $false

$Mutex = New-Object Threading.Mutex($false, $MutexName, [ref]$IsMutexCreated)

if (-not $IsMutexCreated) {
    Terminate 'Another instance of the script is already running!' -ExitCode 1
}


$BackupRoot = Join-Path (Split-Path -Parent $PSCommandPath) 'ProfileBackup'
$TempProfilePath = "C:\Users\$TempAdmin"
$BackupDir = Join-Path $BackupRoot 'TempAdminCleanup'

# ── Helpers ──────────────────────────────────────────────────────────────────────────────────────────────────────────

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
}

function Get-TempAdminSids {
    $sidSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $profileKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\ProfileList'
    )

    foreach ($profileKey in $profileKeys) {
        if (-not (Test-Path -Literal $profileKey)) {
            continue
        }

        foreach ($child in Get-ChildItem -Path $profileKey -ErrorAction SilentlyContinue) {
            try {
                $profileImagePath = Get-ItemPropertyValue -Path $child.PSPath -Name 'ProfileImagePath' -ErrorAction Stop
                if ($profileImagePath -ieq $TempProfilePath) {
                    $null = $sidSet.Add($child.PSChildName)
                }
            } catch {
            }
        }
    }

    $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPath -ieq $TempProfilePath }
    foreach ($profile in $profiles) {
        $null = $sidSet.Add($profile.SID)
    }

    $gpRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\DataStore'
    if (Test-Path -Literal $gpRoot) {
        foreach ($child in Get-ChildItem -Path $gpRoot -ErrorAction SilentlyContinue) {
            try {
                $values = (Get-ItemProperty -Path $child.PSPath).PSObject.Properties.Value
                if (($values -join ' ') -match [regex]::Escape($TempAdmin)) {
                    $null = $sidSet.Add($child.PSChildName)
                }
            } catch {
            }
        }
    }

    return [string[]]$sidSet
}

function Grant-RegistryKeyFullControl {
    param([string]$RegistryPath)

    $acl = Get-Acl -Path $RegistryPath
    $owner = New-Object System.Security.Principal.NTAccount('Administrators')
    $acl.SetOwner($owner)
    Set-Acl -Path $RegistryPath -AclObject $acl

    $acl = Get-Acl -Path $RegistryPath
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
        'Administrators',
        'FullControl',
        'ContainerInherit',
        'None',
        'Allow'
    )
    $acl.SetAccessRule($rule)
    Set-Acl -Path $RegistryPath -AclObject $acl
}

function Remove-RegistryKeyRobust {
    param([string]$RegistryPath)

    if (-not (Test-Path -Literal $RegistryPath)) {
        return
    }

    try {
        Remove-Item -Path $RegistryPath -Recurse -Force -ErrorAction Stop
    } catch {
        Grant-RegistryKeyFullControl -RegistryPath $RegistryPath
        Remove-Item -Path $RegistryPath -Recurse -Force
    }
}

function Find-WindowsSearchTempAdminKeys {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows Search',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Search'
    )

    $matches = New-Object System.Collections.Generic.List[string]
    $tempPattern = [regex]::Escape($TempProfilePath)
    $namePattern = [regex]::Escape($TempAdmin)

    foreach ($root in $roots) {
        if (-not (Test-Path -Literal $root)) {
            continue
        }

        foreach ($key in Get-ChildItem -Path $root -Recurse -ErrorAction SilentlyContinue) {
            try {
                $props = (Get-ItemProperty -Path $key.PSPath).PSObject.Properties
                foreach ($prop in $props) {
                    if ($prop.Name -in 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') {
                        continue
                    }

                    if ($prop.Value -is [string] -and ($prop.Value -match $tempPattern -or $prop.Value -match $namePattern)) {
                        $matches.Add($key.PSPath)
                        break
                    }
                }
            } catch {
            }
        }
    }

    return $matches | Sort-Object -Unique
}

# ── Cleanup ──────────────────────────────────────────────────────────────────────────────────────────────────────────

Create-Directory -Path $BackupDir

Invoke-RegExport -Key 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Destination (Join-Path $BackupDir 'ProfileList_64.reg')
Invoke-RegExport -Key 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\ProfileList' -Destination (Join-Path $BackupDir 'ProfileList_32.reg')
Invoke-RegExport -Key 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\DataStore' -Destination (Join-Path $BackupDir 'GroupPolicy_DataStore.reg')
Invoke-RegExport -Key 'HKLM\SOFTWARE\Microsoft\Windows Search' -Destination (Join-Path $BackupDir 'WindowsSearch_64.reg')
Invoke-RegExport -Key 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows Search' -Destination (Join-Path $BackupDir 'WindowsSearch_32.reg')

$tempAdminSids = Get-TempAdminSids

$localUser = Get-LocalUser -Name $TempAdmin -ErrorAction SilentlyContinue
if ($localUser) {
    Remove-LocalGroupMember -Group 'Administrators' -Member $TempAdmin -ErrorAction SilentlyContinue
    Remove-LocalUser -Name $TempAdmin
    Write-Host "Removed local user $TempAdmin" -ForegroundColor Green
}

$tempProfiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPath -ieq $TempProfilePath }
foreach ($profile in $tempProfiles) {
    Remove-CimInstance -InputObject $profile -ErrorAction SilentlyContinue
    Write-Host "Removed Win32_UserProfile $($profile.SID)" -ForegroundColor Green
}

if (Test-Path -Literal $TempProfilePath) {
    Remove-Item -Path $TempProfilePath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed folder $TempProfilePath" -ForegroundColor Green
}

foreach ($sid in $tempAdminSids) {
    Remove-RegistryKeyRobust -RegistryPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    Remove-RegistryKeyRobust -RegistryPath "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    Remove-RegistryKeyRobust -RegistryPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\DataStore\$sid"
    Write-Host "Removed registry keys for SID $sid" -ForegroundColor Green
}

$searchKeys = Find-WindowsSearchTempAdminKeys
foreach ($searchKey in $searchKeys) {
    Remove-RegistryKeyRobust -RegistryPath $searchKey
    Write-Host "Removed Windows Search key $searchKey" -ForegroundColor Green
}


} catch {
    Write-Output $_
    Terminate -ExitCode 1
} finally {
    if ($Mutex) {
        $Mutex.Close()
    }
}

Write-Host ''
Write-Host "Cleanup complete for temporary account $TempAdmin." -ForegroundColor Green
Write-Host "Verify with: reg query HKLM\SOFTWARE /f $TempAdmin /s" -ForegroundColor Yellow