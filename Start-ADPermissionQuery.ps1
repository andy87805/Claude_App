#Requires -Version 5.1
<#
.SYNOPSIS
    資料夾 / 共用路徑權限查詢工具（AD 環境用，全程唯讀）。

.DESCRIPTION
    1. 輸入資料夾路徑（本機或 \\server\share\...）
    2. 列出有哪些人員、群組有權限（權限種類、允許/拒絕、套用範圍、是否繼承）
    3. 選擇群組 → 列出成員（姓名、帳號、部門、職稱、Email、帳號狀態、最後登入…）
    其他功能：巢狀群組展開、反查使用者權限、子資料夾權限差異掃描、關鍵字篩選、
             匯出 CSV / HTML、查詢紀錄 log。

    本工具只會「讀取」AD 與 NTFS 權限，不會新增、修改或刪除任何 AD 物件或權限。

.PARAMETER Path
    直接指定要查詢的路徑（不指定會在啟動後詢問）。

.PARAMETER Server
    指定要查詢的網域控制站或網域（例如 dc01.corp.local），不指定則自動尋找。

.PARAMETER InactiveDays
    超過幾天未登入就標示為「久未登入」，預設 90。

.PARAMETER LogPath
    查詢紀錄檔位置，預設 %LOCALAPPDATA%\ADPermissionQuery\query.log。

.PARAMETER NoLog
    不寫查詢紀錄。

.PARAMETER NoGui
    不使用 Out-GridView 視窗，全部用文字選單（適合 Server Core / 遠端工作階段）。

.EXAMPLE
    .\Start-ADPermissionQuery.ps1

.EXAMPLE
    .\Start-ADPermissionQuery.ps1 -Path '\\fileserver\share\財務部' -InactiveDays 60
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
try {
    # 讓主控台正確顯示中文
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}
catch {
    Write-Verbose "無法設定主控台編碼（不影響查詢）：$($_.Exception.Message)"
}

if (Get-Module -ListAvailable -Name ActiveDirectory) {
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
}
Import-Module (Join-Path $PSScriptRoot 'ADPermissionQuery.psm1') -Force

$opt = @{ InactiveDays = $InactiveDays; NoLog = $NoLog; NoGui = $NoGui }
if ($Server)  { $opt['Server'] = $Server }
if ($LogPath) { $opt['LogPath'] = $LogPath }
Set-ADPermissionQueryOption @opt

Start-ADPermissionQuery -Path $Path
