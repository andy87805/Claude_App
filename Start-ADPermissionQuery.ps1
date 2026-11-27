#Requires -Version 5.1
<#
.SYNOPSIS
    Active Directory permission query (read-only) and management tool.

.DESCRIPTION
    Main menu: folder permissions, group members, user / computer info and groups,
    compare two users' groups, account search, and where a group is used on folders.
    The query part only READS AD and NTFS permissions.
    If ADManagement.psm1 is in the same folder, a top menu also offers the management part
    (create groups / users, add / remove group members, Excel import). Every change is shown
    as a preview (dry run) first and only runs after you type YES. Use -QueryOnly to hide it.
    See README.md for the full (Traditional Chinese) documentation.

    NOTE: This launcher is intentionally plain ASCII so that it works no matter how the file was
    downloaded or saved (with / without BOM, UTF-8 / ANSI). It loads ADPermissionQuery.psm1 by
    reading it as UTF-8 itself, so the module file also works with or without a BOM.

.PARAMETER Path
    Path to query. If omitted, you will be asked after start-up.

.PARAMETER QueryOnly
    Load only the read-only query part, even if ADManagement.psm1 exists.

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
    [switch]$NoGui,
    [switch]$QueryOnly
)

$ErrorActionPreference = 'Continue'

function Get-TextEncodingName {
    # Detect how the module file was saved:
    #   UTF-8 (with / without BOM), UTF-16 LE / BE (with / without BOM; e.g. Windows PowerShell 5.1
    #   "> file" / Out-File, or Notepad "Unicode"), otherwise the system ANSI code page (e.g. Big5).
    param([byte[]]$Bytes)
    $n = $Bytes.Length
    if ($n -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return 'utf8' }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return 'utf16le' }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return 'utf16be' }

    # No BOM: UTF-16 text has many 0x00 bytes (the high byte of every ASCII character).
    $sample = [Math]::Min($n, 4096)
    $evenZero = 0; $oddZero = 0
    for ($i = 0; $i -lt $sample; $i++) {
        if ($Bytes[$i] -eq 0) { if ($i % 2 -eq 0) { $evenZero++ } else { $oddZero++ } }
    }
    if ($sample -gt 0) {
        if ($oddZero -gt $sample * 0.2 -and $oddZero -gt $evenZero * 4) { return 'utf16le' }
        if ($evenZero -gt $sample * 0.2 -and $evenZero -gt $oddZero * 4) { return 'utf16be' }
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try { [void]$strictUtf8.GetString($Bytes); return 'utf8' } catch { return 'ansi' }
}

function Read-ModuleSource {
    # Read the module file as text, independent of how it was saved (see Get-TextEncodingName),
    # and strip duplicated BOMs.
    param([Parameter(Mandatory)][string]$File)

    $bytes = [System.IO.File]::ReadAllBytes($File)
    $kind = Get-TextEncodingName -Bytes $bytes
    Write-Verbose "ADPermissionQuery.psm1 encoding: $kind"
    switch ($kind) {
        'utf8'    { $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes) }
        'utf16le' { $text = [System.Text.Encoding]::Unicode.GetString($bytes) }
        'utf16be' { $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes) }
        default {
            $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
            $text = [System.Text.Encoding]::GetEncoding($cp).GetString($bytes)
            $kind = "ansi (code page $cp)"
        }
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
    [pscustomobject]@{
        Text     = ($text -replace '(?m)^\s*#Requires[^\r\n]*', '')
        Encoding = $kind
    }
}

$modulePath = Join-Path $PSScriptRoot 'ADPermissionQuery.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Error "Cannot find ADPermissionQuery.psm1. Put it in the same folder as this script: $PSScriptRoot"
    return
}

if (Get-Module -ListAvailable -Name ActiveDirectory) {
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
}

function Import-ToolModule {
    # Load a module file through Read-ModuleSource. Returns $false (with one clear message) if it cannot be read.
    param([string]$File, [string]$Name)
    $source = Read-ModuleSource -File $File
    # Check the module text first, so a damaged file gives one clear message instead of many parse errors.
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($source.Text, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $msg = ("{3} could not be read correctly (detected encoding: {0}; first error at line {1}: {2}) " +
            "The file is probably damaged. Please download it again (GitHub: Code > Download ZIP, or the 'Download raw file' button) " +
            "and do not convert or re-save it.") -f $source.Encoding, $parseErrors[0].Extent.StartLineNumber, $parseErrors[0].Message, (Split-Path $File -Leaf)
        Write-Error $msg
        return $false
    }
    New-Module -Name $Name -ScriptBlock ([scriptblock]::Create($source.Text)) | Import-Module -Force -Global
    return $true
}

if (-not (Import-ToolModule -File $modulePath -Name 'ADPermissionQuery')) { return }

# Optional management part (changes AD). Loaded only when the file exists and -QueryOnly is not used.
$managementPath = Join-Path $PSScriptRoot 'ADManagement.psm1'
$withManagement = $false
if (-not $QueryOnly -and (Test-Path -LiteralPath $managementPath)) {
    $withManagement = Import-ToolModule -File $managementPath -Name 'ADManagement'
    if (-not $withManagement) { return }
}

$opt = @{ InactiveDays = $InactiveDays; NoLog = $NoLog; NoGui = $NoGui }
if ($Server)  { $opt['Server'] = $Server }
if ($LogPath) { $opt['LogPath'] = $LogPath }
Set-ADPermissionQueryOption @opt

if ($withManagement) { Start-ADTool -Path $Path }
else { Start-ADPermissionQuery -Path $Path }
