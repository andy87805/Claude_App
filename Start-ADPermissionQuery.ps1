#Requires -Version 5.1
<#
.SYNOPSIS
    Folder / share permission query tool for Active Directory (READ-ONLY).

.DESCRIPTION
    Enter a folder or UNC path, list who has permissions, pick a group and list its members.
    This tool only READS AD and NTFS permissions. It never creates, changes or deletes anything in AD.
    See README.md for the full (Traditional Chinese) documentation.

    NOTE: This launcher is intentionally plain ASCII so that it works no matter how the file was
    downloaded or saved (with / without BOM, UTF-8 / ANSI). It loads ADPermissionQuery.psm1 by
    reading it as UTF-8 itself, so the module file also works with or without a BOM.

.PARAMETER Path
    Path to query. If omitted, you will be asked after start-up.

.PARAMETER Server
    Domain controller or domain to query (e.g. dc01.corp.local). Auto-detected if omitted.

.PARAMETER InactiveDays
    Mark accounts that have not logged on for more than N days. Default 90.

.PARAMETER LogPath
    Query log file. Default %LOCALAPPDATA%\ADPermissionQuery\query.log

.PARAMETER NoLog
    Do not write the query log.

.PARAMETER NoGui
    Do not use Out-GridView windows; text menus only (Server Core / remote sessions).

.EXAMPLE
    .\Start-ADPermissionQuery.ps1

.EXAMPLE
    .\Start-ADPermissionQuery.ps1 -Path '\\fileserver\share\Finance' -InactiveDays 60
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$Server,
    [ValidateRange(1, 3650)][int]$InactiveDays = 90,
    [string]$LogPath,
    [switch]$NoLog,
    [switch]$NoGui
)

$ErrorActionPreference = 'Continue'

function Read-ModuleSource {
    # Read the module file as text, independent of how it was saved:
    #   UTF-8 with BOM, UTF-8 without BOM, duplicated BOM, or ANSI (e.g. Big5 saved by Notepad).
    param([Parameter(Mandatory)][string]$File)

    $bytes = [System.IO.File]::ReadAllBytes($File)
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $text = $strictUtf8.GetString($bytes)
    }
    catch {
        # Not valid UTF-8: the file was saved in the system ANSI code page.
        $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        Write-Verbose "Module file is not UTF-8, decoding with ANSI code page $cp."
        $text = [System.Text.Encoding]::GetEncoding($cp).GetString($bytes)
    }

    # Strip any leading BOM characters, including a BOM that was turned into text
    # (U+FEFF, or the three characters EF BB BF shown as Latin-1).
    $mojibakeBom = [string]::new([char[]](0xEF, 0xBB, 0xBF))
    $changed = $true
    while ($changed) {
        $changed = $false
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1); $changed = $true }
        elseif ($text.StartsWith($mojibakeBom)) { $text = $text.Substring(3); $changed = $true }
    }
    if ($text.IndexOf([char]0xFFFD) -ge 0) {
        Write-Warning 'ADPermissionQuery.psm1 contains broken characters; Chinese text may be garbled. Please re-download the file (see README).'
    }
    # '#Requires' is already declared by this launcher.
    return ($text -replace '(?m)^\s*#Requires[^\r\n]*', '')
}

$modulePath = Join-Path $PSScriptRoot 'ADPermissionQuery.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Error "Cannot find ADPermissionQuery.psm1. Put it in the same folder as this script: $PSScriptRoot"
    return
}

if (Get-Module -ListAvailable -Name ActiveDirectory) {
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
}

$source = Read-ModuleSource -File $modulePath
New-Module -Name ADPermissionQuery -ScriptBlock ([scriptblock]::Create($source)) | Import-Module -Force

$opt = @{ InactiveDays = $InactiveDays; NoLog = $NoLog; NoGui = $NoGui }
if ($Server)  { $opt['Server'] = $Server }
if ($LogPath) { $opt['LogPath'] = $LogPath }
Set-ADPermissionQueryOption @opt

Start-ADPermissionQuery -Path $Path
