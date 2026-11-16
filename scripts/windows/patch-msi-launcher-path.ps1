# Adds the installed app directory to PATH in the jpackage MSI.
#
# jpackage's Windows launcher restarts itself once so that <install>\app is on
# PATH. While waiting it pumps a hidden message-only window; on some machines
# (reported with Windows 11 24H2/25H2 and Brazilian banking modules such as
# Warsaw/G-Buster) GetMessage() fails with ERROR_INVALID_WINDOW_HANDLE (1400)
# and the app never starts.
#
# If <install>\app is already on PATH, the launcher runs the JVM in-process and
# never enters that message loop. This script edits the MSI Environment table so
# the installer appends the directory and removes it on uninstall.
#
# See https://github.com/NuvioMedia/NuvioDesktop/issues/829

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MsiPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$environmentRowId = 'NuvioLauncherPath'
$launcherFileName = 'Nuvio.exe'
# MSI Environment values use [~] for the null character and append the value
# after the existing entry with a semicolon.
$appDirValue = '[~];[INSTALLDIR]app'
# "=" sets the value on install, "-" removes it on uninstall, "*" writes it to
# the machine environment because jpackage produces a per-machine MSI.
$pathRowName = '=-*PATH'
$writeAction = 'WriteEnvironmentStrings'
$removeAction = 'RemoveEnvironmentStrings'
$writeSequence = 5200
$removeSequence = 3300

function Test-MsiRow {
    param(
        [Parameter(Mandatory = $true)] $Database,
        [Parameter(Mandatory = $true)] [string]$Sql
    )

    $view = $null
    try {
        $view = $Database.OpenView($Sql)
        $view.Execute()
        $record = $view.Fetch()
        return $null -ne $record
    } finally {
        if ($null -ne $view) {
            $view.Close()
        }
    }
}

function Get-FreeSequence {
    param(
        [Parameter(Mandatory = $true)] $Database,
        [Parameter(Mandatory = $true)] [int]$Preferred,
        [Parameter(Mandatory = $true)] [int]$Minimum,
        [Parameter(Mandatory = $true)] [int]$Maximum
    )

    for ($candidate = $Preferred; $candidate -le $Maximum; $candidate++) {
        $sql = 'SELECT `Action` FROM `InstallExecuteSequence` WHERE `Sequence` = ' + $candidate
        if (-not (Test-MsiRow -Database $Database -Sql $sql)) {
            return $candidate
        }
    }

    throw "No free InstallExecuteSequence slot between $Minimum and $Maximum."
}

function Add-MsiSequenceAction {
    param(
        [Parameter(Mandatory = $true)] $Installer,
        [Parameter(Mandatory = $true)] $Database,
        [Parameter(Mandatory = $true)] [string]$Action,
        [Parameter(Mandatory = $true)] [int]$PreferredSequence
    )

    $exists = Test-MsiRow -Database $Database -Sql (
        'SELECT `Action` FROM `InstallExecuteSequence` WHERE `Action` = ''' + $Action + '''')
    if ($exists) {
        Write-Host "InstallExecuteSequence already contains $Action."
        return
    }

    $sequence = Get-FreeSequence `
        -Database $Database `
        -Preferred $PreferredSequence `
        -Minimum 1000 `
        -Maximum 6500

    $view = $null
    try {
        $view = $Database.OpenView(
            'INSERT INTO `InstallExecuteSequence` (`Action`, `Condition`, `Sequence`) VALUES (?, ?, ?)')
        $record = $Installer.CreateRecord(3)
        $record.StringData(1) = $Action
        $record.StringData(2) = ''
        $record.IntegerData(3) = $sequence
        $view.Execute($record)
        Write-Host "Scheduled $Action at sequence $sequence."
    } finally {
        if ($null -ne $view) {
            $view.Close()
        }
    }
}

$resolvedMsi = (Resolve-Path -LiteralPath $MsiPath).Path
if (-not (Test-Path -LiteralPath $resolvedMsi -PathType Leaf)) {
    throw "MSI file not found: $resolvedMsi"
}

$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase($resolvedMsi, 1)

$hasEnvironmentTable = Test-MsiRow -Database $database -Sql (
    'SELECT `Name` FROM `_Tables` WHERE `Name` = ''Environment''')
if (-not $hasEnvironmentTable) {
    $createView = $null
    try {
        $createView = $database.OpenView(
            'CREATE TABLE `Environment` (`Environment` CHAR(72) NOT NULL, ' +
            '`Name` CHAR(255) NOT NULL LOCALIZABLE, `Value` CHAR(255) LOCALIZABLE, ' +
            '`Component_` CHAR(72) NOT NULL PRIMARY KEY `Environment`)')
        $createView.Execute()
        Write-Host 'Created MSI Environment table.'
    } finally {
        if ($null -ne $createView) {
            $createView.Close()
        }
    }
}

$componentSql = 'SELECT `Component_` FROM `File` WHERE `FileName` = ''' + $launcherFileName + ''''
$componentView = $null
$component = $null
try {
    $componentView = $database.OpenView($componentSql)
    $componentView.Execute()
    $record = $componentView.Fetch()
    if ($null -ne $record) {
        $component = $record.StringData(1)
    }
} finally {
    if ($null -ne $componentView) {
        $componentView.Close()
    }
}

if ([string]::IsNullOrWhiteSpace($component)) {
    throw "Could not find the MSI component that owns $launcherFileName."
}
Write-Host "Launcher component: $component"

$existingSql = 'SELECT `Name`, `Value`, `Component_` FROM `Environment` ' +
    'WHERE `Environment` = ''' + $environmentRowId + ''''
$existingView = $null
$existing = $null
try {
    $existingView = $database.OpenView($existingSql)
    $existingView.Execute()
    $existing = $existingView.Fetch()
    if ($null -ne $existing) {
        $existingName = $existing.StringData(1)
        $existingValue = $existing.StringData(2)
        $existingComponent = $existing.StringData(3)
        if ($existingName -ne $pathRowName -or
            $existingValue -ne $appDirValue -or
            $existingComponent -ne $component) {
            throw "The MSI already has an unexpected $environmentRowId environment row."
        }
        Write-Host 'Launcher PATH environment row already exists.'
    }
} finally {
    if ($null -ne $existingView) {
        $existingView.Close()
    }
}

if ($null -eq $existing) {
    $insertView = $null
    try {
        $insertView = $database.OpenView(
            'INSERT INTO `Environment` (`Environment`, `Name`, `Value`, `Component_`) ' +
            'VALUES (?, ?, ?, ?)')
        $record = $installer.CreateRecord(4)
        $record.StringData(1) = $environmentRowId
        $record.StringData(2) = $pathRowName
        $record.StringData(3) = $appDirValue
        $record.StringData(4) = $component
        $insertView.Execute($record)
        Write-Host 'Added the launcher app directory to the installed PATH.'
    } finally {
        if ($null -ne $insertView) {
            $insertView.Close()
        }
    }
}

Add-MsiSequenceAction `
    -Installer $installer `
    -Database $database `
    -Action $writeAction `
    -PreferredSequence $writeSequence
Add-MsiSequenceAction `
    -Installer $installer `
    -Database $database `
    -Action $removeAction `
    -PreferredSequence $removeSequence

$database.Commit()

if (-not (Test-MsiRow -Database $database -Sql $existingSql)) {
    throw 'MSI environment row verification failed after commit.'
}
foreach ($action in @($writeAction, $removeAction)) {
    $actionSql = 'SELECT `Action` FROM `InstallExecuteSequence` WHERE `Action` = ''' + $action + ''''
    if (-not (Test-MsiRow -Database $database -Sql $actionSql)) {
        throw "MSI $action sequence verification failed after commit."
    }
}

Write-Host "Patched $resolvedMsi"
