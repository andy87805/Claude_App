#Requires -Version 5.1
<#
    ADManagement.psm1
    AD 管理功能：新增群組 / 使用者、加入 / 移除群組成員、從 Excel / CSV 批次匯入、用還原清單復原。

    ★ 這個模組「會修改 AD」，因此：
      1. 所有動作都先建立「變更計畫」並預覽（dry run）：每一筆會做什麼、略過什麼、哪裡有錯，預覽時不會修改 AD。
      2. 確認後要輸入大寫 YES 才會執行；執行後產生結果報表與還原清單。
      3. 會修改 AD 的指令只出現在 Invoke-ADChangeItem 這一個函式中
         （tests\ManagementSafety.Tests.ps1 會靜態掃描確認，並檢查只有輸入 YES 後才會執行）。
    ★ 需要先載入 ADPermissionQuery.psm1（共用顯示 / 查詢函式）。
#>

$script:Mgmt = @{
    LastUndoPath = $null
}
$script:MaxBatchRows = 5000

# ---------------------------------------------------------------------------
# 欄位名稱對照（Excel 標題可用中文或英文，標題後面的 * 會被忽略）
# ---------------------------------------------------------------------------
$script:FieldAliases = @{
    Group      = [ordered]@{
        Name           = @('群組名稱', '名稱', 'GroupName', 'Name')
        SamAccountName = @('帳號', '群組帳號', 'sAMAccountName', 'SamAccountName')
        Path           = @('OU', '路徑', '位置', 'Path')
        Scope          = @('範圍', '群組範圍', 'GroupScope', 'Scope')
        Category       = @('類型', '群組類型', 'GroupCategory', 'Category')
        DisplayName    = @('顯示名稱', 'DisplayName')
        Description    = @('描述', 'Description')
        Info           = @('附註', '備註', 'Notes', 'Info')
        Members        = @('成員', 'Members')
        MemberOf       = @('加入到群組', '所屬群組', 'MemberOf')
    }
    User       = [ordered]@{
        SamAccountName        = @('帳號', '使用者帳號', 'sAMAccountName', 'SamAccountName')
        Surname               = @('姓', 'Surname', 'LastName')
        GivenName             = @('名', 'GivenName', 'FirstName')
        DisplayName           = @('顯示名稱', '姓名', 'DisplayName')
        Path                  = @('OU', '路徑', '位置', 'Path')
        UserPrincipalName     = @('UPN', '登入名稱', 'UserPrincipalName')
        EmailAddress          = @('Email', 'E-mail', '電子郵件', 'Mail', 'EmailAddress')
        Department            = @('部門', 'Department')
        Title                 = @('職稱', 'Title')
        Company               = @('公司', 'Company')
        Office                = @('辦公室', 'Office')
        OfficePhone           = @('電話', 'OfficePhone', 'Phone', 'TelephoneNumber')
        MobilePhone           = @('手機', 'MobilePhone', 'Mobile')
        EmployeeID            = @('員工編號', 'EmployeeID')
        Manager               = @('主管', '主管帳號', 'Manager')
        Description           = @('描述', 'Description')
        Info                  = @('附註', '備註', 'Notes', 'Info')
        AccountExpirationDate = @('帳號到期日', '到期日', 'AccountExpirationDate')
        Enabled               = @('啟用', 'Enabled')
        MemberOf              = @('加入群組', '群組', 'MemberOf')
    }
    Membership = [ordered]@{
        Group  = @('群組', '群組名稱', 'Group')
        Member = @('成員', '帳號', '成員帳號', 'Member')
    }
    Move       = [ordered]@{
        Object   = @('物件', '帳號', '名稱', '物件名稱', 'Object', 'Identity', 'SamAccountName', 'Name')
        SourceOU = @('目前 OU', '來源 OU', '原 OU', '目前位置', 'SourceOU', 'From')
        TargetOU = @('目標 OU', '新 OU', '搬到', 'TargetOU', 'To', 'TargetPath')
    }
}

# 工作表名稱 → 資料種類
$script:SheetKinds = [ordered]@{
    Group         = @('群組', 'Groups', 'Group', '新增群組')
    User          = @('使用者', 'Users', 'User', '新增使用者')
    AddMember     = @('群組成員', '加入成員', 'Members', 'AddMembers')
    RemoveMember  = @('移除成員', 'RemoveMembers')
    Move          = @('搬移', '搬移物件', 'Move', 'MoveObjects')
}

# ---------------------------------------------------------------------------
# 讀取 Excel（.xlsx）與 CSV —— 不需要安裝 Excel 或其他模組
# ---------------------------------------------------------------------------
function Get-XmlChildText {
    param($Node, [string]$LocalName)
    foreach ($c in $Node.ChildNodes) { if ($c.LocalName -eq $LocalName) { return $c.InnerText } }
    return $null
}

function Get-SharedStringText {
    <# 共用字串（含多段格式的文字），不含注音 / 拼音 #>
    param($Si)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Si.ChildNodes) {
        if ($c.LocalName -eq 't') { [void]$sb.Append($c.InnerText) }
        elseif ($c.LocalName -eq 'r') { $t = Get-XmlChildText $c 't'; if ($t) { [void]$sb.Append($t) } }
    }
    return $sb.ToString()
}

function ConvertFrom-ColumnLetter {
    param([string]$Ref)
    $letters = ($Ref -replace '[0-9]', '').ToUpperInvariant()
    $n = 0
    foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int]$ch - 64) }
    return $n - 1
}

function Read-ZipEntryXml {
    param($Zip, [string]$Name)
    $e = $Zip.GetEntry($Name)
    if (-not $e) { return $null }
    $sr = New-Object System.IO.StreamReader($e.Open(), [System.Text.Encoding]::UTF8)
    try { $xml = New-Object System.Xml.XmlDocument; $xml.LoadXml($sr.ReadToEnd()); return $xml }
    finally { $sr.Dispose() }
}

function Get-DateStyleSet {
    <# 找出哪些儲存格樣式是日期格式，讀到數字時才知道要轉成日期 #>
    param($StylesXml)
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    if (-not $StylesXml) { return , $set }
    $custom = @{}
    foreach ($n in $StylesXml.GetElementsByTagName('numFmt')) {
        $custom[[int]$n.GetAttribute('numFmtId')] = $n.GetAttribute('formatCode')
    }
    $cellXfs = $StylesXml.GetElementsByTagName('cellXfs')
    if ($cellXfs.Count -eq 0) { return , $set }
    $i = 0
    foreach ($xf in $cellXfs[0].ChildNodes) {
        if ($xf.LocalName -ne 'xf') { continue }
        $id = 0; [void][int]::TryParse($xf.GetAttribute('numFmtId'), [ref]$id)
        $isDate = ($id -ge 14 -and $id -le 22) -or ($id -ge 45 -and $id -le 47) -or ($id -ge 27 -and $id -le 36) -or ($id -ge 50 -and $id -le 58)
        if (-not $isDate -and $custom.ContainsKey($id)) {
            $code = ($custom[$id] -replace '"[^"]*"', '' -replace '\[[^\]]*\]', '')
            $isDate = $code -match '[yYdD]' -or ($code -match 'm' -and $code -notmatch '0')
        }
        if ($isDate) { [void]$set.Add($i) }
        $i++
    }
    return , $set
}

function Read-XlsxWorkbook {
    <# 讀取 .xlsx：回傳 [ordered] 工作表名稱 → 資料列（每列含 __Row 列號） #>
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    # 用共用讀取模式開檔，Excel 正開著這個檔案時也能讀
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
    }
    catch {
        $fs.Dispose()
        throw "無法讀取 Excel 檔（可能不是 .xlsx 格式，或檔案已損壞）：$($_.Exception.Message)"
    }
    try {
        $shared = @()
        $ss = Read-ZipEntryXml $zip 'xl/sharedStrings.xml'
        if ($ss) { $shared = @(foreach ($si in $ss.DocumentElement.ChildNodes) { if ($si.LocalName -eq 'si') { Get-SharedStringText $si } }) }
        $dateStyles = Get-DateStyleSet (Read-ZipEntryXml $zip 'xl/styles.xml')

        $wb = Read-ZipEntryXml $zip 'xl/workbook.xml'
        $rels = Read-ZipEntryXml $zip 'xl/_rels/workbook.xml.rels'
        if (-not $wb -or -not $rels) { throw '找不到工作表資料，檔案可能不是 Excel 活頁簿。' }
        $relMap = @{}
        foreach ($r in $rels.DocumentElement.ChildNodes) { if ($r.LocalName -eq 'Relationship') { $relMap[$r.GetAttribute('Id')] = $r.GetAttribute('Target') } }

        $result = [ordered]@{}
        $relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
        foreach ($sheet in $wb.GetElementsByTagName('sheet')) {
            $name = $sheet.GetAttribute('name')
            $target = $relMap[$sheet.GetAttribute('id', $relNs)]
            if (-not $target) { continue }
            $entry = if ($target.StartsWith('/')) { $target.TrimStart('/') } else { 'xl/' + $target }
            $sx = Read-ZipEntryXml $zip $entry
            if (-not $sx) { continue }

            $rows = New-Object System.Collections.Generic.List[object]
            foreach ($row in $sx.GetElementsByTagName('row')) {
                $rowNum = [int]$row.GetAttribute('r')
                $cells = @{}
                $auto = 0
                foreach ($c in $row.ChildNodes) {
                    if ($c.LocalName -ne 'c') { continue }
                    $ref = $c.GetAttribute('r')
                    $col = if ($ref) { ConvertFrom-ColumnLetter $ref } else { $auto }
                    $auto = $col + 1
                    $t = $c.GetAttribute('t')
                    $v = Get-XmlChildText $c 'v'
                    $text = switch ($t) {
                        's'         { if ($null -ne $v) { $shared[[int]$v] } else { '' } }
                        'inlineStr' { $is = $null; foreach ($x in $c.ChildNodes) { if ($x.LocalName -eq 'is') { $is = $x } }; if ($is) { Get-SharedStringText $is } else { '' } }
                        'b'         { if ($v -eq '1') { 'TRUE' } else { 'FALSE' } }
                        default     {
                            if ($null -eq $v) { '' }
                            else {
                                $style = 0; [void][int]::TryParse($c.GetAttribute('s'), [ref]$style)
                                $num = 0.0
                                if ($t -ne 'str' -and $dateStyles.Contains($style) -and [double]::TryParse($v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)) {
                                    $d = [DateTime]::FromOADate($num)
                                    if ($d.TimeOfDay.TotalSeconds -lt 1) { $d.ToString('yyyy-MM-dd') } else { $d.ToString('yyyy-MM-dd HH:mm') }
                                }
                                elseif ($t -ne 'str' -and [double]::TryParse($v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num) -and $num -eq [Math]::Floor($num) -and [Math]::Abs($num) -lt 1e15) {
                                    ([decimal]$num).ToString([System.Globalization.CultureInfo]::InvariantCulture)
                                }
                                else { $v }
                            }
                        }
                    }
                    $cells[$col] = [string]$text
                }
                $rows.Add([pscustomobject]@{ Row = $rowNum; Cells = $cells })
            }
            $result[$name] = ConvertFrom-CellRows -Rows $rows.ToArray()
        }
        return $result
    }
    finally {
        $zip.Dispose()
        $fs.Dispose()
    }
}

function ConvertFrom-CellRows {
    <# 第一個非空白列當標題，其餘列轉成物件；整列空白的略過 #>
    param([object[]]$Rows)
    $header = $null
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Rows) {
        $nonEmpty = @($r.Cells.Values | Where-Object { "$_".Trim() -ne '' })
        if ($nonEmpty.Count -eq 0) { continue }
        if (-not $header) { $header = $r.Cells; continue }
        $o = [ordered]@{ __Row = $r.Row }
        foreach ($k in ($header.Keys | Sort-Object)) {
            $h = "$($header[$k])".Trim()
            if (-not $h -or $o.Contains($h)) { continue }
            $o[$h] = if ($r.Cells.ContainsKey($k)) { "$($r.Cells[$k])".Trim() } else { '' }
        }
        $out.Add([pscustomobject]$o)
    }
    return , $out.ToArray()
}

function Read-CsvFile {
    <# 讀取 CSV：自動判斷 UTF-8（含 / 不含 BOM）、UTF-16、ANSI（Big5） #>
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = $null
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2) }
    else {
        try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
        catch {
            $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
            $text = [System.Text.Encoding]::GetEncoding($cp).GetString($bytes)
        }
    }
    $lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
    $data = @($lines | ConvertFrom-Csv)
    $n = 1
    $rows = foreach ($d in $data) {
        $n++
        $o = [ordered]@{ __Row = $n }
        $empty = $true
        foreach ($p in $d.PSObject.Properties) {
            $v = "$($p.Value)".Trim()
            if ($v) { $empty = $false }
            $o[$p.Name.Trim()] = $v
        }
        if (-not $empty) { [pscustomobject]$o }
    }
    return , @($rows)
}

function Import-Spreadsheet {
    <#
    .SYNOPSIS
        讀取 Excel（.xlsx / .xlsm）或 CSV，回傳 [ordered] 工作表名稱 → 資料列。CSV 的工作表名稱為 'CSV'。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "找不到檔案：$Path" }
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        '.xlsx' { return (Read-XlsxWorkbook -Path $Path) }
        '.xlsm' { return (Read-XlsxWorkbook -Path $Path) }
        '.csv'  { $r = [ordered]@{}; $r['CSV'] = Read-CsvFile -Path $Path; return $r }
        '.xls'  { throw '不支援舊版 .xls 格式，請在 Excel 中「另存新檔」為 .xlsx 後再匯入。' }
        default { throw "不支援的檔案格式「$ext」，請使用 .xlsx 或 .csv。" }
    }
}

function ConvertTo-FieldRows {
    <#
        依欄位對照表把資料列轉成標準欄位名稱。
        回傳 @{ Rows = 轉換後的列; Unknown = 無法辨識的欄位名稱 }
    #>
    param([object[]]$Rows, [ValidateSet('Group', 'User', 'Membership', 'Move')][string]$Kind, [string]$SheetName = '')
    $aliases = $script:FieldAliases[$Kind]
    $lookup = @{}
    foreach ($field in $aliases.Keys) { foreach ($a in $aliases[$field]) { $lookup[($a -replace '\s', '').ToLowerInvariant()] = $field } }
    $unknown = New-Object System.Collections.Generic.List[string]
    $map = @{}
    if ($Rows.Count -gt 0) {
        foreach ($p in $Rows[0].PSObject.Properties) {
            if ($p.Name -eq '__Row') { continue }
            $key = ($p.Name -replace '[\*＊\s]', '').ToLowerInvariant()
            if ($lookup.ContainsKey($key)) { $map[$p.Name] = $lookup[$key] } else { $unknown.Add($p.Name) }
        }
    }
    $out = foreach ($r in $Rows) {
        $o = [ordered]@{ Source = $(if ($SheetName) { "$SheetName!$($r.__Row)" } else { "第 $($r.__Row) 列" }) }
        foreach ($field in $aliases.Keys) { $o[$field] = '' }
        foreach ($p in $r.PSObject.Properties) { if ($map.ContainsKey($p.Name)) { $o[$map[$p.Name]] = "$($p.Value)".Trim() } }
        [pscustomobject]$o
    }
    @{ Rows = @($out); Unknown = $unknown.ToArray() }
}

function Get-SheetKind {
    param([string]$SheetName)
    foreach ($k in $script:SheetKinds.Keys) {
        foreach ($n in $script:SheetKinds[$k]) { if ($SheetName.Trim() -ieq $n) { return $k } }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 產生 Excel 範本
# ---------------------------------------------------------------------------
function ConvertTo-XmlText {
    param([string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

function New-SheetXml {
    param([string[]]$Header, [object[]]$Rows, [int[]]$Widths)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
    [void]$sb.Append('<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>')
    [void]$sb.Append('<cols>')
    for ($i = 0; $i -lt $Header.Count; $i++) {
        $w = if ($Widths -and $i -lt $Widths.Count) { $Widths[$i] } else { 16 }
        [void]$sb.Append("<col min=`"$($i + 1)`" max=`"$($i + 1)`" width=`"$w`" customWidth=`"1`"/>")
    }
    [void]$sb.Append('</cols><sheetData>')
    $all = @(, $Header) + @($Rows)
    for ($r = 0; $r -lt $all.Count; $r++) {
        [void]$sb.Append("<row r=`"$($r + 1)`">")
        $vals = @($all[$r])
        for ($c = 0; $c -lt $vals.Count; $c++) {
            $col = ''
            $n = $c + 1
            while ($n -gt 0) { $m = ($n - 1) % 26; $col = [char](65 + $m) + $col; $n = [int][Math]::Floor(($n - 1) / 26) }
            $style = if ($r -eq 0) { ' s="1"' } else { '' }
            [void]$sb.Append("<c r=`"$col$($r + 1)`" t=`"inlineStr`"$style><is><t xml:space=`"preserve`">$(ConvertTo-XmlText ([string]$vals[$c]))</t></is></c>")
        }
        [void]$sb.Append('</row>')
    }
    [void]$sb.Append('</sheetData></worksheet>')
    return $sb.ToString()
}

function New-ImportTemplate {
    <#
    .SYNOPSIS
        產生批次匯入用的 Excel 範本（.xlsx），含「群組」「使用者」「群組成員」「移除成員」「說明」工作表。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$DomainDN = 'DC=corp,DC=local')
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $sheets = @(
        @{ Name = '群組'; Header = @('群組名稱*', '帳號', 'OU*', '範圍', '類型', '顯示名稱', '描述', '附註', '成員', '加入到群組')
            Widths = @(22, 18, 34, 10, 10, 18, 26, 26, 26, 22)
            Rows = @(, @('財務部-檔案讀寫', 'FIN-FS-RW', "OU=Groups,$DomainDN", '網域本機', '安全性', '', '財務部共用資料夾讀寫', '申請單 2026-001', 'alice;bob', '')) }
        @{ Name = '使用者'; Header = @('帳號*', '姓', '名', '顯示名稱', 'OU*', 'UPN', 'Email', '部門', '職稱', '公司', '辦公室', '電話', '手機', '員工編號', '主管', '描述', '附註', '帳號到期日', '啟用', '加入群組')
            Widths = @(14, 8, 10, 14, 34, 24, 24, 12, 12, 12, 10, 12, 14, 12, 12, 20, 20, 14, 8, 24)
            Rows = @(, @('wang.dm', '王', '大明', '王大明', "OU=Users,$DomainDN", '', 'wang.dm@example.com', '財務部', '專員', '', '', '#1234', '', 'E1001', 'alice', '新進人員', '到職日 2026-12-01', '', '是', 'FIN-FS-RW')) }
        @{ Name = '群組成員'; Header = @('群組*', '成員*'); Widths = @(26, 26); Rows = @(@('FIN-FS-RW', 'carol'), @('FIN-FS-RW', 'PC01')) }
        @{ Name = '移除成員'; Header = @('群組*', '成員*'); Widths = @(26, 26); Rows = @(, @('Old-Project-Team', 'dave')) }
        @{ Name = '搬移'; Header = @('物件*', '目前 OU', '目標 OU*'); Widths = @(24, 30, 34)
            Rows = @(@('chen.xm', '台北/業務部', '台北/財務部/帳號'), @('PC-FIN-01', '', '台北/財務部/電腦')) }
        @{ Name = '說明'; Header = @('項目', '說明'); Widths = @(18, 100)
            Rows = @(
                , @('使用方式', '在要用的工作表填資料（第 1 列標題不要改），不需要的工作表可以刪除或留空。匯入時會先預覽，確認後輸入 YES 才會執行。')
                , @('必填欄位', '標題有 * 的欄位必填。OU 空白時，匯入時可以指定一個預設 OU。')
                , @('OU', '可以用 / 分隔，由上往下寫（和 AD 樹狀圖相同），例如 台北/財務部/帳號；也可以填完整的 DN，例如 OU=帳號,OU=財務部,OU=台北,' + $DomainDN)
                , @('群組 範圍', '全域 / 網域本機 / 萬用（空白 = 全域）')
                , @('群組 類型', '安全性 / 發佈（空白 = 安全性）')
                , @('成員 / 加入群組', '可填多個帳號或群組，用 ; 或 , 分隔。成員可以是使用者、群組或電腦（電腦填名稱即可）。')
                , @('使用者 帳號', '最多 20 個字元，不能包含 " / \ [ ] : ; | = , + * ? < > @')
                , @('顯示名稱', '空白時使用「姓 + 名」')
                , @('UPN', '空白時使用「帳號@網域」')
                , @('主管', '填主管的帳號；主管若也是這次新增的人，必須排在前面的列')
                , @('帳號到期日', '格式 2026-12-31，表示可以使用到當天結束')
                , @('啟用', '是 / 否（空白 = 是）')
                , @('初始密碼', '匯入時輸入一組共用的初始密碼（不會存在任何檔案），使用者第一次登入時必須變更')
                , @('已存在的物件', '群組或帳號已存在時會略過，不會修改既有物件；但仍會處理該列要加入的成員 / 群組')
                , @('搬移 物件', '填帳號（電腦可以只填名稱）、名稱或 DN；可以搬移使用者、群組、電腦')
                , @('搬移 目前 OU', '可以空白。有填但物件不在這個 OU 時，會自動查出實際位置，並詢問你要不要照實際位置搬移')
                , @('搬移 目標 OU', '要搬到哪個 OU，寫法和其他 OU 欄位相同（例如 台北/財務部/帳號）')
            ) }
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $write = {
            param($name, $content)
            $e = $zip.CreateEntry($name)
            $w = New-Object System.IO.StreamWriter($e.Open(), $utf8)
            try { $w.Write($content) } finally { $w.Dispose() }
        }
        $ct = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        for ($i = 1; $i -le $sheets.Count; $i++) { $ct += "<Override PartName=`"/xl/worksheets/sheet$i.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/>" }
        $ct += '</Types>'
        & $write '[Content_Types].xml' $ct
        & $write '_rels/.rels' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
        $wbx = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
        $relx = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        for ($i = 1; $i -le $sheets.Count; $i++) {
            $wbx += "<sheet name=`"$(ConvertTo-XmlText $sheets[$i - 1].Name)`" sheetId=`"$i`" r:id=`"rId$i`"/>"
            $relx += "<Relationship Id=`"rId$i`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet`" Target=`"worksheets/sheet$i.xml`"/>"
        }
        $n = $sheets.Count + 1
        $relx += "<Relationship Id=`"rId$n`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles`" Target=`"styles.xml`"/></Relationships>"
        & $write 'xl/workbook.xml' ($wbx + '</sheets></workbook>')
        & $write 'xl/_rels/workbook.xml.rels' $relx
        & $write 'xl/styles.xml' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Microsoft JhengHei"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Microsoft JhengHei"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF2B579A"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'
        for ($i = 1; $i -le $sheets.Count; $i++) {
            $sh = $sheets[$i - 1]
            & $write "xl/worksheets/sheet$i.xml" (New-SheetXml -Header $sh.Header -Rows $sh.Rows -Widths $sh.Widths)
        }
    }
    finally {
        $zip.Dispose()
        $fs.Dispose()
    }
    Write-QueryLog -Action '產生匯入範本' -Target $Path
    return $Path
}

# ---------------------------------------------------------------------------
# 變更計畫（預覽 / dry run）—— 這一段只會「查詢」AD，不會修改任何東西
# ---------------------------------------------------------------------------
# 執行順序：搬移放最後，前面的成員變更才能用搬移前的 DN
$script:ActionOrder = @{ '新增群組' = 1; '新增使用者' = 2; '加入成員' = 3; '移除成員' = 4; '刪除使用者' = 5; '刪除群組' = 6; '搬移物件' = 7 }
$script:InvalidSamChars = '["/\\\[\]:;|=,+*?<>@]'

function New-PlanContext {
    param([securestring]$Password, [string]$DefaultOU)
    @{
        Password   = $Password
        DefaultOU  = $DefaultOU
        Planned    = @{}      # 這次要新增的物件：帳號（小寫）→ @{ Class; Sam; Name; DN; Order }
        PlannedCN  = @{}      # "OU|名稱" → 來源（避免同一個 OU 內新增兩個同名物件）
        Items      = New-Object System.Collections.Generic.List[object]
        MemberRows = New-Object System.Collections.Generic.List[object]
        Principal  = @{}
        Container  = @{}
        Members    = @{}
        Upn        = @{}
        Domain     = $null    # @{ DN; DNS }
        OUPath     = @{}      # OU 欄位文字 → 轉換結果
        Policy     = $null
        PolicyRead = $false
        Order      = 0
    }
}

function New-PlanItem {
    param([string]$Source, [string]$Action, [string]$Target, [string]$Detail, [string[]]$Errors = @(), [string]$Skip = '', [string]$Note = '', [hashtable]$Data = @{})
    $status = '將執行'; $reason = $Note
    if ($Errors.Count -gt 0) { $status = '錯誤'; $reason = ($Errors -join '；') }
    elseif ($Skip) { $status = '略過'; $reason = $Skip }
    [pscustomobject]@{
        No = 0; Source = $Source; Action = $Action; Target = $Target; Detail = $Detail
        Status = $status; Reason = $reason; Data = $Data; Result = ''; Message = ''
    }
}

function Split-NameList {
    param([string]$Text)
    @("$Text" -split '[;,；，、\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Find-ADPrincipal {
    <# 用帳號找 AD 物件（使用者、群組、電腦）；找不到再看是不是這次要新增的。回傳 $null 表示都找不到 #>
    param($Ctx, [string]$Name)
    $sam = Get-SamFromInput $Name
    if (-not $sam) { return $null }
    $key = $sam.ToLowerInvariant()
    if (-not $Ctx.Principal.ContainsKey($key)) {
        $srv = Get-ADServerParam
        $found = $null
        $props = @('sAMAccountName', 'objectClass', 'objectGUID', 'displayName', 'name', 'distinguishedName')
        try {
            if ($sam -match '^(CN|OU)=') {
                $found = Get-ADObject -Identity $sam -Properties $props @srv -ErrorAction Stop
            }
            else {
                $found = Get-ADObject -Filter "sAMAccountName -eq '$(ConvertTo-LdapFilterValue $sam)'" -Properties $props @srv -ErrorAction Stop | Select-Object -First 1
                if (-not $found -and -not $sam.EndsWith('$')) {
                    $found = Get-ADObject -Filter "sAMAccountName -eq '$(ConvertTo-LdapFilterValue ($sam + '$'))'" -Properties $props @srv -ErrorAction Stop | Select-Object -First 1
                }
            }
        }
        catch { $found = $null }
        $Ctx.Principal[$key] = if ($found) {
            @{ Exists = $true; Class = [string](@($found.objectClass)[-1]); Sam = [string]$found.sAMAccountName; DN = [string]$found.distinguishedName
                Name = [string]$found.name; Guid = [string]$found.objectGUID }
        }
        else { $null }
    }
    if ($Ctx.Principal[$key]) { return $Ctx.Principal[$key] }
    if ($Ctx.Planned.ContainsKey($key)) { return $Ctx.Planned[$key] }
    return $null
}

function Test-ADContainer {
    <# OU / 容器是否存在 #>
    param($Ctx, [string]$DN)
    if (-not $Ctx.Container.ContainsKey($DN)) {
        $srv = Get-ADServerParam
        $ok = $false
        try { $o = Get-ADObject -Identity $DN @srv -ErrorAction Stop; $ok = [bool]$o } catch { $ok = $false }
        $Ctx.Container[$DN] = $ok
    }
    return $Ctx.Container[$DN]
}

function Test-NameConflict {
    <# OU 內是否已有同名物件（CN 不能重複） #>
    param($Ctx, [string]$Name, [string]$Path)
    $srv = Get-ADServerParam
    try {
        $o = Get-ADObject -Filter "Name -eq '$(ConvertTo-LdapFilterValue $Name)'" -SearchBase $Path -SearchScope OneLevel @srv -ErrorAction Stop | Select-Object -First 1
        return [bool]$o
    }
    catch { return $false }
}

function Get-DirectMemberSet {
    param($Ctx, [string]$GroupDN)
    if (-not $Ctx.Members.ContainsKey($GroupDN)) {
        $srv = Get-ADServerParam
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        try {
            $g = Get-ADGroup -Identity $GroupDN -Properties member @srv -ErrorAction Stop
            foreach ($m in @($g.member)) { if ($m) { [void]$set.Add([string]$m) } }
        }
        catch { Write-Verbose "讀取群組成員失敗：$GroupDN" }
        $Ctx.Members[$GroupDN] = $set
    }
    return , $Ctx.Members[$GroupDN]
}

function Get-DomainInfo {
    <# 網域的 DN（DC=corp,DC=local）與 DNS 名稱（corp.local） #>
    param($Ctx)
    if (-not $Ctx.Domain) {
        $srv = Get-ADServerParam
        try {
            $d = Get-ADDomain @srv -ErrorAction Stop
            $Ctx.Domain = @{ DN = [string]$d.DistinguishedName; DNS = [string]$d.DNSRoot }
        }
        catch { $Ctx.Domain = @{ DN = ''; DNS = '' } }
    }
    return $Ctx.Domain
}

function Get-UpnSuffix {
    param($Ctx)
    return (Get-DomainInfo $Ctx).DNS
}

function ConvertTo-DNValue {
    <# DN 中名稱的特殊字元要在前面加 \（例如 研發, 一部 → 研發\, 一部） #>
    param([string]$Text)
    return ($Text -replace '([\\,+"<>;=#])', '\$1')
}

function Resolve-OUPath {
    <#
    .SYNOPSIS
        把 OU 欄位轉成 DN。可以填：
          - 完整 DN：OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local（照原樣使用）
          - 用 / 分隔的路徑，由上往下寫（和 AD 樹狀圖相同）：台北/財務部/帳號
            開頭可加網域名稱（corp.local/台北/財務部/帳號），也可以用 \ 分隔
        路徑會逐層查詢：每一層先找 OU，找不到再找同名的內建容器（例如 Users）。
        回傳 @{ DN; Display; Error }（只查詢 AD，不會修改）
    #>
    param($Ctx, [string]$Text)
    $t = "$Text".Trim()
    if (-not $t) { return @{ DN = ''; Display = ''; Error = '' } }
    if ($t -match '^(OU|CN|DC)\s*=') { return @{ DN = $t; Display = $t; Error = '' } }
    $key = $t.ToLowerInvariant()
    if ($Ctx.OUPath.ContainsKey($key)) { return $Ctx.OUPath[$key] }

    $segs = @($t -split '[/\\]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $dom = Get-DomainInfo $Ctx
    $result = $null
    if (-not $dom.DN) {
        $result = @{ DN = ''; Display = $t; Error = '無法取得網域名稱，請改填完整的 DN（例如 OU=帳號,OU=財務部,DC=corp,DC=local）' }
    }
    else {
        if ($segs.Count -gt 0 -and $dom.DNS -and $segs[0] -ieq $dom.DNS) { $segs = @($segs | Select-Object -Skip 1) }
        if ($segs.Count -eq 0) {
            $result = @{ DN = ''; Display = $t; Error = 'OU 路徑是空的' }
        }
        else {
            $parent = $dom.DN
            $err = ''
            $walked = @()
            foreach ($seg in $segs) {
                $walked += $seg
                $v = ConvertTo-DNValue $seg
                $ou = "OU=$v,$parent"
                $cn = "CN=$v,$parent"
                if ($err) { $parent = $ou; continue }
                if (Test-ADContainer $Ctx $ou) { $parent = $ou }
                elseif (Test-ADContainer $Ctx $cn) { $parent = $cn }
                else {
                    $err = "找不到「$seg」這一層（$($walked -join '/')）"
                    $parent = $ou
                }
            }
            $result = @{ DN = $parent; Display = ($segs -join '/'); Error = $err }
        }
    }
    $Ctx.OUPath[$key] = $result
    return $result
}

function ConvertFrom-SecurePlain {
    param([securestring]$Secure)
    if (-not $Secure) { return '' }
    return (New-Object System.Net.NetworkCredential('', $Secure)).Password
}

function Test-PasswordPolicy {
    <# 依網域預設密碼原則檢查初始密碼；回傳不符合的原因（空陣列 = 通過） #>
    param($Ctx, [securestring]$Password, [string]$Sam, [string]$DisplayName)
    if (-not $Ctx.PolicyRead) {
        $Ctx.PolicyRead = $true
        $srv = Get-ADServerParam
        try { $Ctx.Policy = Get-ADDefaultDomainPasswordPolicy @srv -ErrorAction Stop } catch { $Ctx.Policy = $null }
    }
    $problems = New-Object System.Collections.Generic.List[string]
    $plain = ConvertFrom-SecurePlain $Password
    try {
        $min = 7; $complex = $true
        if ($Ctx.Policy) { $min = [int]$Ctx.Policy.MinPasswordLength; $complex = [bool]$Ctx.Policy.ComplexityEnabled }
        if ($plain.Length -lt $min) { $problems.Add("密碼至少要 $min 個字元") }
        if ($complex) {
            $kinds = 0
            if ($plain -cmatch '[A-Z]') { $kinds++ }
            if ($plain -cmatch '[a-z]') { $kinds++ }
            if ($plain -match '[0-9]') { $kinds++ }
            if ($plain -match '[^A-Za-z0-9]') { $kinds++ }
            if ($kinds -lt 3) { $problems.Add('密碼需包含大寫、小寫、數字、符號其中 3 種') }
            if ($Sam.Length -ge 3 -and $plain.IndexOf($Sam, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $problems.Add('密碼不能包含帳號名稱') }
            foreach ($tok in @("$DisplayName" -split '[,\.\-_#\s]+')) {
                if ($tok.Length -ge 3 -and $plain.IndexOf($tok, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $problems.Add('密碼不能包含姓名中連續 3 個以上的字'); break }
            }
        }
    }
    finally { $plain = $null }
    return $problems.ToArray()
}

function ConvertTo-GroupScopeValue {
    param([string]$Text)
    switch -Regex ("$Text".Trim()) {
        '^$'                                  { return 'Global' }
        '^(全域|global)$'                     { return 'Global' }
        '^(網域本機|本機|domainlocal|domain local)$' { return 'DomainLocal' }
        '^(萬用|universal)$'                  { return 'Universal' }
    }
    return $null
}

function ConvertTo-GroupCategoryValue {
    param([string]$Text)
    switch -Regex ("$Text".Trim()) {
        '^$'                             { return 'Security' }
        '^(安全性|安全|security)$'       { return 'Security' }
        '^(發佈|通訊群組|distribution)$' { return 'Distribution' }
    }
    return $null
}

function ConvertTo-BoolValue {
    param([string]$Text, [bool]$Default = $true)
    switch -Regex ("$Text".Trim()) {
        '^$'                           { return $Default }
        '^(是|y|yes|true|1|啟用)$'     { return $true }
        '^(否|n|no|false|0|停用)$'     { return $false }
    }
    return $null
}

function Add-GroupPlan {
    param($Ctx, [object[]]$Rows)
    $seen = @{}
    $scopeText = @{ Global = '全域'; DomainLocal = '網域本機'; Universal = '萬用' }
    $catText = @{ Security = '安全性'; Distribution = '發佈' }
    foreach ($r in $Rows) {
        $errors = New-Object System.Collections.Generic.List[string]
        $name = "$($r.Name)".Trim()
        $sam = if ("$($r.SamAccountName)".Trim()) { "$($r.SamAccountName)".Trim() } else { $name }
        $ouText = if ("$($r.Path)".Trim()) { "$($r.Path)".Trim() } else { "$($Ctx.DefaultOU)" }
        $ouInfo = Resolve-OUPath $Ctx $ouText
        $path = $ouInfo.DN
        $scope = ConvertTo-GroupScopeValue $r.Scope
        $cat = ConvertTo-GroupCategoryValue $r.Category

        if (-not $name) { $errors.Add('群組名稱是空的') }
        if ($sam -match $script:InvalidSamChars) { $errors.Add('帳號含有不允許的字元（" / \ [ ] : ; | = , + * ? < > @）') }
        if ($sam.Length -gt 64) { $errors.Add('帳號超過 64 個字元') }
        if (-not $scope) { $errors.Add("範圍「$($r.Scope)」無法辨識（全域 / 網域本機 / 萬用）") }
        if (-not $cat) { $errors.Add("類型「$($r.Category)」無法辨識（安全性 / 發佈）") }
        if (-not $ouText) { $errors.Add('沒有指定 OU') }
        elseif ($ouInfo.Error) { $errors.Add("OU 有誤：$($ouInfo.Display)，$($ouInfo.Error)") }
        elseif (-not (Test-ADContainer $Ctx $path)) { $errors.Add("OU 不存在：$path") }
        $key = $sam.ToLowerInvariant()
        if ($sam -and $seen.ContainsKey($key)) { $errors.Add("與 $($seen[$key]) 重複") }
        if ($sam) { $seen[$key] = $r.Source }

        $skip = ''
        if ($errors.Count -eq 0) {
            $existing = Find-ADPrincipal $Ctx $sam
            if ($existing -and $existing.Exists) {
                if ($existing.Class -eq 'group') { $skip = '群組已存在（不會變更既有群組）' }
                else { $errors.Add("帳號「$sam」已被其他物件（$($existing.Class)）使用") }
            }
            elseif ($Ctx.PlannedCN.ContainsKey("$path|$name".ToLowerInvariant()) -or (Test-NameConflict $Ctx $name $path)) {
                $errors.Add("這個 OU 中已有名稱為「$name」的物件")
            }
        }

        $parts = @("OU：$(if ($ouInfo.Display) { $ouInfo.Display } else { $path })")
        if ($scope) { $parts += "範圍：$($scopeText[$scope])" }
        if ($cat) { $parts += "類型：$($catText[$cat])" }
        if ($r.Description) { $parts += "描述：$($r.Description)" }
        if ($r.Info) { $parts += "附註：$($r.Info)" }
        $item = New-PlanItem -Source $r.Source -Action '新增群組' -Target $(if ($sam -ne $name) { "$name（$sam）" } else { $name }) -Detail ($parts -join '；') -Errors $errors.ToArray() -Skip $skip -Data @{
            Name = $name; SamAccountName = $sam; Path = $path; GroupScope = $scope; GroupCategory = $cat
            DisplayName = "$($r.DisplayName)".Trim(); Description = "$($r.Description)".Trim(); Info = "$($r.Info)".Trim()
        }
        $Ctx.Items.Add($item)
        if ($item.Status -eq '將執行') {
            $Ctx.Order++
            $Ctx.Planned[$key] = @{ Exists = $false; Class = 'group'; Sam = $sam; Name = $name; DN = "CN=$name,$path"; Order = $Ctx.Order }
            $Ctx.PlannedCN["$path|$name".ToLowerInvariant()] = $r.Source
        }
        if ($item.Status -ne '錯誤') {
            foreach ($m in (Split-NameList $r.Members)) { $Ctx.MemberRows.Add([pscustomobject]@{ Source = $r.Source; Group = $sam; Member = $m }) }
            foreach ($g in (Split-NameList $r.MemberOf)) { $Ctx.MemberRows.Add([pscustomobject]@{ Source = $r.Source; Group = $g; Member = $sam }) }
        }
    }
}

function Add-UserPlan {
    param($Ctx, [object[]]$Rows)
    $seen = @{}
    $seenUpn = @{}
    foreach ($r in $Rows) {
        $errors = New-Object System.Collections.Generic.List[string]
        $sam = Get-SamFromInput "$($r.SamAccountName)"
        $given = "$($r.GivenName)".Trim(); $sur = "$($r.Surname)".Trim()
        $display = "$($r.DisplayName)".Trim()
        if (-not $display) { $display = ("$sur$given").Trim() }
        if (-not $display) { $display = $sam }
        $ouText = if ("$($r.Path)".Trim()) { "$($r.Path)".Trim() } else { "$($Ctx.DefaultOU)" }
        $ouInfo = Resolve-OUPath $Ctx $ouText
        $path = $ouInfo.DN

        if (-not $sam) { $errors.Add('帳號是空的') }
        elseif ($sam -match $script:InvalidSamChars) { $errors.Add('帳號含有不允許的字元（" / \ [ ] : ; | = , + * ? < > @）') }
        elseif ($sam.Length -gt 20) { $errors.Add('帳號超過 20 個字元') }
        elseif ($sam.EndsWith('.')) { $errors.Add('帳號不能以「.」結尾') }
        if (-not $ouText) { $errors.Add('沒有指定 OU') }
        elseif ($ouInfo.Error) { $errors.Add("OU 有誤：$($ouInfo.Display)，$($ouInfo.Error)") }
        elseif (-not (Test-ADContainer $Ctx $path)) { $errors.Add("OU 不存在：$path") }

        $upn = "$($r.UserPrincipalName)".Trim()
        if (-not $upn -and $sam) {
            $suffix = Get-UpnSuffix $Ctx
            if ($suffix) { $upn = "$sam@$suffix" }
        }
        if ($upn -and $upn -notmatch '^[^@\s]+@[^@\s]+$') { $errors.Add("UPN 格式不正確：$upn") }
        if ($r.EmailAddress -and "$($r.EmailAddress)" -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $errors.Add("Email 格式不正確：$($r.EmailAddress)") }

        $enabled = ConvertTo-BoolValue $r.Enabled $true
        if ($null -eq $enabled) { $errors.Add("啟用欄位「$($r.Enabled)」無法辨識（是 / 否）") }

        $expires = $null; $expireText = ''
        if ("$($r.AccountExpirationDate)".Trim()) {
            $d = [datetime]::MinValue
            $formats = [string[]]@('yyyy-MM-dd', 'yyyy/MM/dd', 'yyyy-M-d', 'yyyy/M/d', 'yyyy-MM-dd HH:mm', 'yyyy/MM/dd HH:mm')
            if ([datetime]::TryParseExact("$($r.AccountExpirationDate)".Trim(), $formats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
                # AD 的到期日是「到這個時間點就失效」；填 12/31 表示 12/31 當天還能用，所以設成隔天 0 點
                $expires = $d.Date.AddDays(1); $expireText = "到期：可使用到 $($d.ToString('yyyy-MM-dd'))"
            }
            else { $errors.Add("帳號到期日「$($r.AccountExpirationDate)」格式不正確（例如 2026-12-31）") }
        }

        $key = "$sam".ToLowerInvariant()
        if ($sam -and $seen.ContainsKey($key)) { $errors.Add("與 $($seen[$key]) 重複") }
        if ($sam) { $seen[$key] = $r.Source }
        if ($upn) {
            $uk = $upn.ToLowerInvariant()
            if ($seenUpn.ContainsKey($uk)) { $errors.Add("UPN 與 $($seenUpn[$uk]) 重複") }
            $seenUpn[$uk] = $r.Source
        }

        $managerRef = ''
        if ("$($r.Manager)".Trim()) {
            $mgr = Find-ADPrincipal $Ctx $r.Manager
            if (-not $mgr -or $mgr.Class -ne 'user') { $errors.Add("找不到主管帳號：$($r.Manager)") }
            elseif (-not $mgr.Exists) { $managerRef = $mgr.Sam }   # 主管也是這次新增的（排在前面），執行時已建立
            else { $managerRef = $mgr.DN }
        }

        $skip = ''
        if ($errors.Count -eq 0) {
            $existing = Find-ADPrincipal $Ctx $sam
            if ($existing -and $existing.Exists) {
                if ($existing.Class -eq 'user' -or $existing.Class -eq 'inetOrgPerson') { $skip = '帳號已存在（不會變更既有帳號）' }
                else { $errors.Add("帳號「$sam」已被其他物件（$($existing.Class)）使用") }
            }
            else {
                if ($upn -and -not $Ctx.Upn.ContainsKey($upn)) {
                    $srv = Get-ADServerParam
                    try { $Ctx.Upn[$upn] = [bool](Get-ADUser -Filter "UserPrincipalName -eq '$(ConvertTo-LdapFilterValue $upn)'" @srv -ErrorAction Stop | Select-Object -First 1) }
                    catch { $Ctx.Upn[$upn] = $false }
                }
                if ($upn -and $Ctx.Upn[$upn]) { $errors.Add("UPN「$upn」已被其他帳號使用") }
                if ($Ctx.PlannedCN.ContainsKey("$path|$display".ToLowerInvariant()) -or (Test-NameConflict $Ctx $display $path)) {
                    $errors.Add("這個 OU 中已有名稱為「$display」的物件（可修改顯示名稱）")
                }
                if (-not $Ctx.Password) { $errors.Add('沒有輸入初始密碼') }
                else {
                    foreach ($p in (Test-PasswordPolicy $Ctx $Ctx.Password $sam $display)) { $errors.Add("初始密碼不符合網域原則：$p") }
                }
            }
        }

        $parts = @("OU：$(if ($ouInfo.Display) { $ouInfo.Display } else { $path })")
        if ($upn) { $parts += "UPN：$upn" }
        foreach ($f in @(@('部門', $r.Department), @('職稱', $r.Title), @('Email', $r.EmailAddress), @('主管', $r.Manager), @('描述', $r.Description), @('附註', $r.Info))) {
            if ("$($f[1])".Trim()) { $parts += "$($f[0])：$($f[1])" }
        }
        if ($expireText) { $parts += $expireText }
        if ($enabled -eq $false) { $parts += '建立後停用' }
        $item = New-PlanItem -Source $r.Source -Action '新增使用者' -Target "$display（$sam）" -Detail ($parts -join '；') -Errors $errors.ToArray() -Skip $skip -Data @{
            Name = $display; SamAccountName = $sam; UserPrincipalName = $upn; Path = $path; GivenName = $given; Surname = $sur; DisplayName = $display
            EmailAddress = "$($r.EmailAddress)".Trim(); Department = "$($r.Department)".Trim(); Title = "$($r.Title)".Trim(); Company = "$($r.Company)".Trim()
            Office = "$($r.Office)".Trim(); OfficePhone = "$($r.OfficePhone)".Trim(); MobilePhone = "$($r.MobilePhone)".Trim(); EmployeeID = "$($r.EmployeeID)".Trim()
            Manager = $managerRef; Description = "$($r.Description)".Trim(); Info = "$($r.Info)".Trim(); AccountExpirationDate = $expires; Enabled = $enabled
        }
        $Ctx.Items.Add($item)
        if ($item.Status -eq '將執行') {
            $Ctx.Order++
            $Ctx.Planned[$key] = @{ Exists = $false; Class = 'user'; Sam = $sam; Name = $display; DN = "CN=$display,$path"; Order = $Ctx.Order }
            $Ctx.PlannedCN["$path|$display".ToLowerInvariant()] = $r.Source
        }
        if ($item.Status -ne '錯誤') {
            foreach ($g in (Split-NameList $r.MemberOf)) { $Ctx.MemberRows.Add([pscustomobject]@{ Source = $r.Source; Group = $g; Member = $sam }) }
        }
    }
}

function Add-MembershipPlan {
    param($Ctx, [object[]]$Rows, [ValidateSet('Add', 'Remove')][string]$Mode)
    $action = if ($Mode -eq 'Add') { '加入成員' } else { '移除成員' }
    $classText = @{ user = '使用者'; inetOrgPerson = '使用者'; group = '群組'; computer = '電腦'; foreignSecurityPrincipal = '外部安全主體' }
    $seen = @{}
    foreach ($r in $Rows) {
        $errors = New-Object System.Collections.Generic.List[string]
        $skip = ''; $note = ''
        $gName = "$($r.Group)".Trim(); $mName = "$($r.Member)".Trim()
        $g = $null; $m = $null
        if (-not $gName) { $errors.Add('群組是空的') }
        else {
            $g = Find-ADPrincipal $Ctx $gName
            if (-not $g) { $errors.Add("找不到群組：$gName") }
            elseif ($g.Class -ne 'group') { $errors.Add("「$gName」不是群組") }
        }
        if (-not $mName) { $errors.Add('成員是空的') }
        else {
            $m = Find-ADPrincipal $Ctx $mName
            if (-not $m) { $errors.Add("找不到成員：$mName") }
        }
        if ($g -and $m -and $g.Sam -ieq $m.Sam) { $errors.Add('群組不能加入自己') }

        $gLabel = if ($g) { $g.Sam } else { $gName }
        $mLabel = if ($m) { "$($m.Sam)（$($classText[$m.Class])）" } else { $mName }
        $key = "$gLabel|$(if ($m) { $m.Sam } else { $mName })".ToLowerInvariant()
        if ($errors.Count -eq 0 -and $seen.ContainsKey($key)) { $skip = "與 $($seen[$key]) 重複" }
        $seen[$key] = $r.Source

        if ($errors.Count -eq 0 -and -not $skip) {
            if ($g.Exists -and $m.Exists) {
                $set = Get-DirectMemberSet $Ctx $g.DN
                $isMember = $set.Contains($m.DN)
                if ($Mode -eq 'Add' -and $isMember) { $skip = '已經是成員' }
                if ($Mode -eq 'Remove' -and -not $isMember) { $skip = '不是這個群組的直接成員' }
            }
            elseif ($Mode -eq 'Remove') { $errors.Add('群組或成員還不存在，無法移除') }
            else { $note = '這次新增的，建立後再加入' }
        }
        $Ctx.Items.Add((New-PlanItem -Source $r.Source -Action $action -Target $gLabel -Detail "成員：$mLabel" -Errors $errors.ToArray() -Skip $skip -Note $note -Data @{
                    Group = $(if ($g -and $g.Exists) { $g.DN } elseif ($g) { $g.Sam } else { '' })
                    Member = $(if ($m -and $m.Exists) { $m.DN } elseif ($m) { $m.Sam } else { '' })
                    GroupSam = $(if ($g) { $g.Sam } else { $gName }); MemberSam = $(if ($m) { $m.Sam } else { $mName })
                }))
    }
}

function Get-ParentDN {
    <# 去掉 DN 的第一段（物件本身），得到所在的 OU / 容器；會處理名稱中跳脫的字元 #>
    param([string]$DN)
    return ($DN -replace '^(?:[^,\\]|\\.)+,', '')
}

function ConvertTo-OUPathText {
    <# 把 DN 轉成好讀的路徑：OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local → 台北/財務部/帳號 #>
    param([string]$DN)
    if (-not $DN) { return '' }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($part in [regex]::Split($DN, '(?<!\\),')) {
        if ($part.Trim() -match '^(?:OU|CN)=(.*)$') { $names.Insert(0, ($Matches[1] -replace '\\(.)', '$1')) }
    }
    if ($names.Count -eq 0) { return '（網域最上層）' }
    return ($names -join '/')
}

function Test-SameDN {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    return (($A -replace ',\s+', ',').Trim() -ieq ($B -replace ',\s+', ',').Trim())
}

function Find-MoveObject {
    <#
        找出要搬移的物件：可填 DN、ObjectGUID、帳號（電腦可省略結尾的 $）或名稱。
        回傳 @{ Object = @{ Name; Sam; DN; Guid; Class; Protected }; Error }（只查詢 AD）
    #>
    param($Ctx, [string]$Text)
    $srv = Get-ADServerParam
    $props = @('sAMAccountName', 'objectClass', 'objectGUID', 'name', 'distinguishedName', 'ProtectedFromAccidentalDeletion')
    $t = "$Text".Trim()
    $list = @()
    try {
        if ($t -match '^(CN|OU)=' -or $t -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
            $list = @(Get-ADObject -Identity $t -Properties $props @srv -ErrorAction Stop)
        }
        else {
            $sam = Get-SamFromInput $t
            $list = @(Get-ADObject -Filter "sAMAccountName -eq '$(ConvertTo-LdapFilterValue $sam)'" -Properties $props @srv -ErrorAction Stop)
            if ($list.Count -eq 0 -and -not $sam.EndsWith('$')) {
                $list = @(Get-ADObject -Filter "sAMAccountName -eq '$(ConvertTo-LdapFilterValue ($sam + '$'))'" -Properties $props @srv -ErrorAction Stop)
            }
            if ($list.Count -eq 0) {
                $list = @(Get-ADObject -Filter "Name -eq '$(ConvertTo-LdapFilterValue $t)'" -Properties $props @srv -ErrorAction Stop |
                    Where-Object { [string](@($_.objectClass)[-1]) -in 'user', 'inetOrgPerson', 'group', 'computer' })
            }
        }
    }
    catch { $list = @() }
    $list = @($list | Where-Object { $_ })
    if ($list.Count -eq 0) { return @{ Object = $null; Error = "找不到物件：$t" } }
    if ($list.Count -gt 1) {
        $where = @($list | ForEach-Object { ConvertTo-OUPathText (Get-ParentDN ([string]$_.distinguishedName)) }) -join '、'
        return @{ Object = $null; Error = "找到 $($list.Count) 個名稱為「$t」的物件（位置：$where），請改填帳號或 DN" }
    }
    $o = $list[0]
    return @{
        Object = @{
            Name = [string]$o.name; Sam = [string]$o.sAMAccountName; DN = [string]$o.distinguishedName; Guid = [string]$o.objectGUID
            Class = [string](@($o.objectClass)[-1]); Protected = [bool]$o.ProtectedFromAccidentalDeletion
        }
        Error  = ''
    }
}

function Add-MovePlan {
    <#
        搬移物件的預覽：查出物件實際所在的 OU。
        Excel 有填「目前 OU」但物件不在那裡時，標示為「需確認」，之後詢問使用者要不要照實際位置搬移。
    #>
    param($Ctx, [object[]]$Rows)
    $classText = @{ user = '使用者'; inetOrgPerson = '使用者'; group = '群組'; computer = '電腦' }
    $seen = @{}
    foreach ($r in $Rows) {
        $errors = New-Object System.Collections.Generic.List[string]
        $skip = ''; $confirm = ''
        $objText = "$($r.Object)".Trim()
        $srcText = "$($r.SourceOU)".Trim()
        $tgtText = "$($r.TargetOU)".Trim()
        $obj = $null
        $label = $objText

        if (-not $objText) { $errors.Add('物件是空的') }
        else {
            $found = Find-MoveObject $Ctx $objText
            if ($found.Error) {
                $plannedKey = (Get-SamFromInput $objText).ToLowerInvariant()
                if ($Ctx.Planned.ContainsKey($plannedKey)) { $errors.Add('這是這次要新增的物件，請直接在新增時填目標 OU') }
                else { $errors.Add($found.Error) }
            }
            else { $obj = $found.Object }
        }
        if ($obj) {
            $who = if ($obj.Sam -and $obj.Sam -ne $obj.Name) { "$($obj.Sam)，" } else { '' }
            $ct = if ($classText.ContainsKey($obj.Class)) { $classText[$obj.Class] } else { $obj.Class }
            $label = "$($obj.Name)（$who$ct）"
            if (-not $classText.ContainsKey($obj.Class)) { $errors.Add("不支援搬移這種物件（$($obj.Class)），只能搬移使用者、群組、電腦") }
            if ($obj.Protected) { $errors.Add('已開啟「防止意外刪除」，無法搬移（可在物件內容的「物件」頁籤取消勾選）') }
            if ($seen.ContainsKey($obj.Guid)) { $errors.Add("與 $($seen[$obj.Guid]) 重複") }
            else { $seen[$obj.Guid] = $r.Source }
        }

        $tgt = Resolve-OUPath $Ctx $tgtText
        if (-not $tgtText) { $errors.Add('沒有填目標 OU') }
        elseif ($tgt.Error) { $errors.Add("目標 OU 有誤：$($tgt.Display)，$($tgt.Error)") }
        elseif (-not (Test-ADContainer $Ctx $tgt.DN)) { $errors.Add("目標 OU 不存在：$($tgt.DN)") }

        $curParent = if ($obj) { Get-ParentDN $obj.DN } else { '' }
        $curText = ConvertTo-OUPathText $curParent
        $tgtPathText = if ($tgt.DN -and -not $tgt.Error) { ConvertTo-OUPathText $tgt.DN } else { $tgtText }

        if ($errors.Count -eq 0) {
            if (Test-SameDN $curParent $tgt.DN) { $skip = '已經在目標 OU' }
            elseif ((Test-NameConflict $Ctx $obj.Name $tgt.DN) -or $Ctx.PlannedCN.ContainsKey("$($tgt.DN)|$($obj.Name)".ToLowerInvariant())) {
                $errors.Add("目標 OU 已有名稱為「$($obj.Name)」的物件")
            }
            elseif ($srcText) {
                $src = Resolve-OUPath $Ctx $srcText
                if ($src.Error -or -not $src.DN) { $confirm = "Excel 填的目前 OU「$srcText」不存在，物件實際在「$curText」" }
                elseif (-not (Test-SameDN $src.DN $curParent)) { $confirm = "Excel 填的目前 OU 是「$(ConvertTo-OUPathText $src.DN)」，但物件實際在「$curText」" }
            }
        }

        $detail = if ($obj) { "從 $curText → 到 $tgtPathText" } else { "到 $tgtPathText" }
        $item = New-PlanItem -Source $r.Source -Action '搬移物件' -Target $label -Detail $detail -Errors $errors.ToArray() -Skip $skip -Data @{
            Identity = $(if ($obj) { $obj.Guid } else { '' }); TargetPath = $tgt.DN; SourcePath = $curParent
            Name = $(if ($obj) { $obj.Name } else { $objText }); Sam = $(if ($obj) { $obj.Sam } else { '' })
            ActualText = $curText; TargetText = $tgtPathText
        }
        if ($confirm -and $item.Status -eq '將執行') { $item.Status = '需確認'; $item.Reason = $confirm }
        $Ctx.Items.Add($item)
        if ($item.Status -eq '將執行' -or $item.Status -eq '需確認') {
            $Ctx.PlannedCN["$($tgt.DN)|$($obj.Name)".ToLowerInvariant()] = $r.Source
        }
    }
}

function Confirm-PendingMove {
    <# 物件不在 Excel 填的 OU 時，詢問要不要照實際位置搬移（全部 / 全部不搬 / 逐筆確認）。只改變預覽狀態，不會修改 AD #>
    param([object[]]$Plan)
    $pending = @($Plan | Where-Object Status -eq '需確認')
    if ($pending.Count -eq 0) { return }
    Show-Table -Rows $pending -Kind Plan -Title "有 $($pending.Count) 筆物件不在 Excel 填的「目前 OU」"
    Write-Status '已幫你查出它們實際所在的 OU（見「說明」欄）。要照實際位置搬到目標 OU 嗎？' -Level Warn
    Show-Options @('Y|全部照實際位置搬移', 'N|全部不搬（略過）', 'O|逐筆確認')
    $c = (Read-Choice '請選擇（直接按 Enter = 全部不搬）').ToUpperInvariant()
    foreach ($p in $pending) {
        $yes = $false
        if ($c -eq 'Y') { $yes = $true }
        elseif ($c -eq 'O') { $yes = Read-YesNo -Prompt "「$($p.Target)」目前在「$($p.Data.ActualText)」，要搬到「$($p.Data.TargetText)」嗎？" -Default $false }
        if ($yes) { $p.Status = '將執行'; $p.Reason = "已確認：從實際位置「$($p.Data.ActualText)」搬移" }
        else { $p.Status = '略過'; $p.Reason = "不在 Excel 填的 OU，選擇不搬（實際在「$($p.Data.ActualText)」）" }
    }
    Write-PlanSummary -Plan $Plan
}

function Complete-Plan {
    param($Ctx)
    $n = 0
    [object[]]$items = $Ctx.Items.ToArray()
    foreach ($i in $items) { $n++; $i.No = $n }
    return , $items
}

function New-ChangePlan {
    <#
    .SYNOPSIS
        建立變更計畫（預覽 / dry run）。只會查詢 AD 驗證每一筆資料，不會修改任何東西。
        回傳每一筆的動作與預覽結果：將執行 / 略過 / 錯誤。
    #>
    [CmdletBinding()]
    param(
        [object[]]$GroupRows = @(),
        [object[]]$UserRows = @(),
        [object[]]$AddMemberRows = @(),
        [object[]]$RemoveMemberRows = @(),
        [object[]]$MoveRows = @(),
        [securestring]$Password,
        [string]$DefaultOU
    )
    $total = $GroupRows.Count + $UserRows.Count + $AddMemberRows.Count + $RemoveMemberRows.Count + $MoveRows.Count
    if ($total -gt $script:MaxBatchRows) { throw "資料超過 $($script:MaxBatchRows) 列，請分批匯入。" }
    $ctx = New-PlanContext -Password $Password -DefaultOU $DefaultOU
    Add-GroupPlan $ctx $GroupRows
    Add-UserPlan $ctx $UserRows
    [object[]]$memberRows = [object[]]$ctx.MemberRows.ToArray() + [object[]]@($AddMemberRows)
    Add-MembershipPlan $ctx $memberRows 'Add'
    Add-MembershipPlan $ctx $RemoveMemberRows 'Remove'
    Add-MovePlan $ctx $MoveRows
    Write-QueryLog -Action '建立變更預覽' -Target "共 $($ctx.Items.Count) 筆"
    return (Complete-Plan $ctx)
}

# ---------------------------------------------------------------------------
# 還原清單
# ---------------------------------------------------------------------------
function New-UndoPlan {
    <#
    .SYNOPSIS
        讀取執行後產生的還原清單（CSV），建立「復原」的變更計畫（一樣先預覽）。
        刪除只會針對清單中記錄的 ObjectGUID，不會刪到後來建立的同名物件。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $rows = @((Import-Spreadsheet -Path $Path)['CSV'])
    $ctx = New-PlanContext
    $srv = Get-ADServerParam
    $addRows = New-Object System.Collections.Generic.List[object]
    $removeRows = New-Object System.Collections.Generic.List[object]
    $moveRows = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) {
        $src = "還原清單!$($r.__Row)"
        $act = "$($r.'動作')"
        switch ($act) {
            { $_ -in '刪除使用者', '刪除群組' } {
                $errors = @(); $skip = ''; $note = ''
                $guid = "$($r.ObjectGUID)".Trim()
                $expect = if ($act -eq '刪除使用者') { 'user' } else { 'group' }
                $o = $null
                if (-not $guid) { $errors += '還原清單沒有 ObjectGUID，無法安全刪除' }
                else {
                    try { $o = Get-ADObject -Identity $guid -Properties sAMAccountName, objectClass, member @srv -ErrorAction Stop } catch { $o = $null }
                    if (-not $o) { $skip = '物件已不存在' }
                    elseif ([string](@($o.objectClass)[-1]) -ne $expect) { $errors += '物件類型與還原清單不符' }
                    elseif ($expect -eq 'group' -and @($o.member).Count -gt 0) { $note = "注意：群組目前有 $(@($o.member).Count) 個成員，刪除後這些成員關係會一起消失" }
                    elseif ($expect -eq 'user') { $note = '注意：刪除使用者無法復原（除非網域有啟用資源回收筒）' }
                }
                $ctx.Items.Add((New-PlanItem -Source $src -Action $act -Target "$($r.'對象')" -Detail "ObjectGUID：$guid" -Errors $errors -Skip $skip -Note $note -Data @{ Identity = $guid }))
            }
            '移除成員' { $removeRows.Add([pscustomobject]@{ Source = $src; Group = $r.'群組'; Member = $r.'成員' }) }
            '加入成員' { $addRows.Add([pscustomobject]@{ Source = $src; Group = $r.'群組'; Member = $r.'成員' }) }
            '搬移物件' {
                $obj = if ("$($r.ObjectGUID)".Trim()) { "$($r.ObjectGUID)".Trim() } else { "$($r.'對象')" }
                $moveRows.Add([pscustomobject]@{ Source = $src; Object = $obj; SourceOU = ''; TargetOU = $r.'目標 OU' })
            }
            default { $ctx.Items.Add((New-PlanItem -Source $src -Action "$act" -Target "$($r.'對象')" -Detail '' -Errors @("無法辨識的動作「$act」"))) }
        }
    }
    Add-MembershipPlan $ctx $addRows.ToArray() 'Add'
    Add-MovePlan $ctx $moveRows.ToArray()
    Add-MembershipPlan $ctx $removeRows.ToArray() 'Remove'
    Write-QueryLog -Action '建立還原預覽' -Target $Path
    return (Complete-Plan $ctx)
}

function Save-UndoList {
    param([object[]]$Done, [string]$Folder)
    $entries = New-Object System.Collections.Generic.List[object]
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    # 反向順序：最後做的最先復原
    for ($i = $Done.Count - 1; $i -ge 0; $i--) {
        $it = $Done[$i]
        if ($it.Action -notin '新增群組', '新增使用者', '加入成員', '移除成員', '搬移物件') { continue }
        $e = [ordered]@{ '動作' = ''; '群組' = ''; '成員' = ''; '對象' = ''; 'ObjectGUID' = ''; '目標 OU' = ''; '原始動作' = $it.Action; '執行時間' = $now }
        switch ($it.Action) {
            '新增群組'   { $e['動作'] = '刪除群組'; $e['對象'] = $it.Data.SamAccountName; $e['ObjectGUID'] = $it.CreatedGuid }
            '新增使用者' { $e['動作'] = '刪除使用者'; $e['對象'] = $it.Data.SamAccountName; $e['ObjectGUID'] = $it.CreatedGuid }
            '加入成員'   { $e['動作'] = '移除成員'; $e['群組'] = $it.Data.GroupSam; $e['成員'] = $it.Data.MemberSam; $e['對象'] = $it.Data.GroupSam }
            '移除成員'   { $e['動作'] = '加入成員'; $e['群組'] = $it.Data.GroupSam; $e['成員'] = $it.Data.MemberSam; $e['對象'] = $it.Data.GroupSam }
            '搬移物件'   { $e['動作'] = '搬移物件'; $e['對象'] = $it.Data.Name; $e['ObjectGUID'] = $it.Data.Identity; $e['目標 OU'] = $it.Data.SourcePath }
        }
        $entries.Add([pscustomobject]$e)
    }
    if ($entries.Count -eq 0) { return $null }
    if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
    $file = Join-Path $Folder ("還原清單_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $enc = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    $entries | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding $enc
    return $file
}

# ---------------------------------------------------------------------------
# 執行 —— ★ 只有這一段會修改 AD
# ---------------------------------------------------------------------------
function Invoke-ADChangeItem {
    <# ★ 整個工具中唯一會修改 AD 的函式（tests\ManagementSafety.Tests.ps1 會檢查） #>
    param([Parameter(Mandatory)]$Item, [securestring]$Password)
    $srv = Get-ADServerParam
    $d = $Item.Data
    switch ($Item.Action) {
        '新增群組' {
            $p = @{ Name = $d.Name; SamAccountName = $d.SamAccountName; Path = $d.Path; GroupScope = $d.GroupScope; GroupCategory = $d.GroupCategory; PassThru = $true; ErrorAction = 'Stop' }
            if ($d.DisplayName) { $p['DisplayName'] = $d.DisplayName }
            if ($d.Description) { $p['Description'] = $d.Description }
            if ($d.Info) { $p['OtherAttributes'] = @{ info = $d.Info } }
            return (New-ADGroup @p @srv)
        }
        '新增使用者' {
            $p = @{ Name = $d.Name; SamAccountName = $d.SamAccountName; Path = $d.Path; AccountPassword = $Password; ChangePasswordAtLogon = $true
                Enabled = [bool]$d.Enabled; PassThru = $true; ErrorAction = 'Stop' }
            foreach ($f in 'UserPrincipalName', 'GivenName', 'Surname', 'DisplayName', 'EmailAddress', 'Department', 'Title', 'Company', 'Office', 'OfficePhone', 'MobilePhone', 'EmployeeID', 'Manager', 'Description') {
                if ($d[$f]) { $p[$f] = $d[$f] }
            }
            if ($d.AccountExpirationDate) { $p['AccountExpirationDate'] = $d.AccountExpirationDate }
            if ($d.Info) { $p['OtherAttributes'] = @{ info = $d.Info } }
            return (New-ADUser @p @srv)
        }
        '加入成員' { Add-ADGroupMember -Identity $d.Group -Members $d.Member -ErrorAction Stop @srv; return $null }
        '移除成員' { Remove-ADGroupMember -Identity $d.Group -Members $d.Member -Confirm:$false -ErrorAction Stop @srv; return $null }
        '搬移物件' { Move-ADObject -Identity $d.Identity -TargetPath $d.TargetPath -Confirm:$false -ErrorAction Stop @srv; return $null }
        '刪除使用者' { Remove-ADUser -Identity $d.Identity -Confirm:$false -ErrorAction Stop @srv; return $null }
        '刪除群組' { Remove-ADGroup -Identity $d.Identity -Confirm:$false -ErrorAction Stop @srv; return $null }
        default { throw "不支援的動作：$($Item.Action)" }
    }
}

function Invoke-ADChangePlan {
    <# 依序執行計畫中「將執行」的項目，回傳 @{ Items; UndoPath; ReportFiles } #>
    param([Parameter(Mandatory)][object[]]$Plan, [securestring]$Password, [string]$Folder)
    if (-not $Folder) { $Folder = Get-DefaultExportFolder }
    $todo = @($Plan | Where-Object { $_.Status -eq '將執行' } | Sort-Object @{ Expression = { $script:ActionOrder[$_.Action] } }, No)
    $done = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($it in $todo) {
        $i++
        Write-Progress -Activity '正在修改 AD' -Status "$($it.Action)：$($it.Target)" -PercentComplete ([int](100 * $i / [Math]::Max(1, $todo.Count)))
        try {
            $o = Invoke-ADChangeItem -Item $it -Password $Password
            $it.Result = '成功'
            if ($o -and $o.ObjectGUID) { $it | Add-Member -NotePropertyName CreatedGuid -NotePropertyValue ([string]$o.ObjectGUID) -Force }
            $done.Add($it)
        }
        catch {
            $it.Result = '失敗'
            $it.Message = $_.Exception.Message
        }
        Write-QueryLog -Action "AD 變更：$($it.Action)（$($it.Result)）" -Target "$($it.Target) $($it.Detail)"
    }
    Write-Progress -Activity '正在修改 AD' -Completed
    foreach ($it in $Plan) {
        if (-not $it.Result) { $it.Result = "未執行（$($it.Status)）"; $it.Message = $it.Reason }
    }
    $undo = Save-UndoList -Done $done.ToArray() -Folder $Folder
    if ($undo) { $script:Mgmt.LastUndoPath = $undo }
    $report = @()
    try { $report = @(Export-QueryReport -Kind PlanResult -InputObject $Plan -Title '執行結果' -Folder $Folder -Format Both) } catch { Write-Verbose "儲存執行結果失敗：$($_.Exception.Message)" }
    [pscustomobject]@{ Items = $Plan; UndoPath = $undo; ReportFiles = $report }
}

# ---------------------------------------------------------------------------
# 預覽與確認畫面
# ---------------------------------------------------------------------------
function Write-PlanSummary {
    param([object[]]$Plan)
    $run = @($Plan | Where-Object Status -eq '將執行').Count
    $skip = @($Plan | Where-Object Status -eq '略過').Count
    $err = @($Plan | Where-Object Status -eq '錯誤').Count
    $ask = @($Plan | Where-Object Status -eq '需確認').Count
    Write-Host ''
    Write-Host '  共 ' -NoNewline; Write-Host "$($Plan.Count)" -NoNewline -ForegroundColor Cyan; Write-Host ' 筆：' -NoNewline
    Write-Host "將執行 $run" -NoNewline -ForegroundColor Green; Write-Host '　' -NoNewline
    if ($ask -gt 0) { Write-Host "需確認 $ask" -NoNewline -ForegroundColor Yellow; Write-Host '　' -NoNewline }
    Write-Host "略過 $skip" -NoNewline -ForegroundColor DarkGray; Write-Host '　' -NoNewline
    if ($err -gt 0) { Write-Host "錯誤 $err" -ForegroundColor Red } else { Write-Host "錯誤 0" }
}

function Get-ActionSummaryText {
    param([object[]]$Items)
    $parts = foreach ($a in @('新增群組', '新增使用者', '加入成員', '移除成員', '搬移物件', '刪除使用者', '刪除群組')) {
        $n = @($Items | Where-Object Action -eq $a).Count
        if ($n -gt 0) { "$a $n 筆" }
    }
    return (@($parts) -join '、')
}

function Read-InitialPassword {
    <# 輸入新帳號的初始密碼（畫面不顯示，不會存到任何檔案）；直接按 Enter 取消 #>
    while ($true) {
        $p1 = Read-Host '  請輸入新帳號的初始密碼（畫面不會顯示；直接按 Enter 取消）' -AsSecureString
        if (-not $p1 -or $p1.Length -eq 0) { return $null }
        $p2 = Read-Host '  請再輸入一次確認' -AsSecureString
        if ((ConvertFrom-SecurePlain $p1) -ceq (ConvertFrom-SecurePlain $p2)) {
            Write-Status '使用者第一次登入時必須變更密碼。' -Level Hint
            return $p1
        }
        Write-Status '兩次輸入的密碼不一樣，請重新輸入。' -Level Warn
    }
}

function Invoke-PlanReview {
    <#
    .SYNOPSIS
        顯示變更預覽（不會修改 AD），使用者確認並輸入大寫 YES 後才執行。
        回傳執行結果；取消時回傳 $null。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Plan, [securestring]$Password, [string]$Title = '變更預覽')
    $current = $Plan
    $first = $true
    while ($true) {
        if ($first) {
            Write-Section "$Title（預覽，尚未修改 AD）"
            Show-Table -Rows $current -Kind Plan
            Write-PlanSummary -Plan $Plan
            $err = @($Plan | Where-Object Status -eq '錯誤').Count
            if ($err -gt 0) { Write-Status "有 $err 筆錯誤，這些不會執行。可以修正後重新匯入，或只執行其他項目。" -Level Warn }
            Confirm-PendingMove -Plan $Plan
            $first = $false
        }
        $run = @($Plan | Where-Object Status -eq '將執行')
        $opts = @()
        if ($run.Count -gt 0) { $opts += "X|確認並執行（$($run.Count) 筆）" }
        $opts += 'R|只看錯誤與略過', 'A|顯示全部', 'E|匯出預覽', 'S|開視窗檢視', 'B|取消（不做任何變更）'
        Show-Options $opts
        $c = (Read-Choice '請選擇').ToUpperInvariant()
        switch ($c) {
            'X' {
                if ($run.Count -eq 0) { Write-Status '沒有可以執行的項目。' -Level Warn; break }
                Write-Section '確認執行'
                Write-Status "即將修改 AD：$(Get-ActionSummaryText $run)" -Level Warn
                $err = @($Plan | Where-Object Status -eq '錯誤').Count
                if ($err -gt 0) { Write-Status "另外有 $err 筆錯誤不會執行。" -Level Hint }
                $ans = Read-Host '  確認無誤請輸入大寫 YES 執行，輸入其他內容取消'
                if ("$ans".Trim() -ceq 'YES') {
                    $res = Invoke-ADChangePlan -Plan $Plan -Password $Password
                    $done = @($res.Items | Where-Object { $_.Result -eq '成功' -or $_.Result -eq '失敗' })
                    Show-Table -Rows $done -Kind PlanResult -Title '執行結果'
                    $ok = @($done | Where-Object Result -eq '成功').Count
                    $fail = @($done | Where-Object Result -eq '失敗').Count
                    if ($fail -eq 0) { Write-Status "全部完成：成功 $ok 筆。" -Level Ok }
                    else { Write-Status "成功 $ok 筆，失敗 $fail 筆（失敗原因請看上表「訊息」欄）。" -Level Warn }
                    foreach ($f in @($res.ReportFiles)) { Write-Status "執行結果報表：$f" -Level Hint }
                    if ($res.UndoPath) { Write-Status "還原清單：$($res.UndoPath)（需要復原時，用管理選單 [8] 載入）" -Level Hint }
                    return $res
                }
                Write-Status '已取消，沒有修改 AD。' -Level Ok
            }
            'R' {
                $current = @($Plan | Where-Object { $_.Status -ne '將執行' })
                Show-Table -Rows $current -Kind Plan -Title "$Title（錯誤與略過）"
            }
            'A' { $current = $Plan; Show-Table -Rows $current -Kind Plan -Title $Title; Write-PlanSummary -Plan $Plan }
            'E' { Read-ExportChoice -Rows $current -Kind Plan -Title '變更預覽' -Subtitle '預覽，尚未修改 AD' }
            'S' { Show-Result -Rows $current -Kind Plan -Title $Title }
            'B' { Write-Status '已取消，沒有修改 AD。' -Level Ok; return $null }
            default { Write-Status '請輸入選單上的代號。' -Level Warn }
        }
    }
}

# ---------------------------------------------------------------------------
# 管理選單
# ---------------------------------------------------------------------------
function Read-Field {
    param([string]$Label, [string]$Default = '', [switch]$Required)
    $hint = ''
    if ($Default) { $hint = "（直接按 Enter = $Default）" }
    elseif ($Required) { $hint = '（必填，直接按 Enter 取消）' }
    $v = Read-Choice "$Label$hint"
    if (-not $v) { $v = $Default }
    return $v
}

function Read-OU {
    param([string]$Kind = '群組')
    $sample = if ($Kind -eq '群組') { '台北/財務部/群組' } else { '台北/財務部/帳號' }
    $def = $script:Mgmt["LastOU_$Kind"]
    $v = Read-Field -Label "OU（例如 $sample，或完整的 DN）" -Default $def -Required
    if ($v) { $script:Mgmt["LastOU_$Kind"] = $v }
    return $v
}

function Invoke-NewGroupForm {
    Write-Section '新增群組（單筆）'
    $name = Read-Field -Label '群組名稱' -Required
    if (-not $name) { return }
    $sam = Read-Field -Label '帳號（sAMAccountName）' -Default $name
    $ou = Read-OU -Kind '群組'
    if (-not $ou) { return }
    $scope = switch (Read-Choice '範圍：[1] 全域  [2] 網域本機  [3] 萬用（直接按 Enter = 1）') { '2' { '網域本機' } '3' { '萬用' } default { '全域' } }
    $cat = switch (Read-Choice '類型：[1] 安全性  [2] 發佈（直接按 Enter = 1）') { '2' { '發佈' } default { '安全性' } }
    $row = [pscustomobject]@{
        Source = '手動輸入'; Name = $name; SamAccountName = $sam; Path = $ou; Scope = $scope; Category = $cat
        DisplayName = ''; Description = (Read-Choice '描述（可空白）'); Info = (Read-Choice '附註（可空白）')
        Members = (Read-Choice '要加入的成員（帳號，多個用 ; 分隔，可空白）'); MemberOf = (Read-Choice '要把這個群組加入哪些群組（多個用 ; 分隔，可空白）')
    }
    $plan = New-ChangePlan -GroupRows @($row)
    [void](Invoke-PlanReview -Plan $plan -Title '新增群組')
}

function Invoke-NewUserForm {
    Write-Section '新增使用者（單筆）'
    $sam = Read-Field -Label '帳號（最多 20 個字元）' -Required
    if (-not $sam) { return }
    $sur = Read-Choice '姓'
    $given = Read-Choice '名'
    $display = Read-Field -Label '顯示名稱' -Default ("$sur$given".Trim())
    $ou = Read-OU -Kind '使用者'
    if (-not $ou) { return }
    $row = [pscustomobject]@{
        Source = '手動輸入'; SamAccountName = $sam; Surname = $sur; GivenName = $given; DisplayName = $display; Path = $ou
        UserPrincipalName = ''; EmailAddress = (Read-Choice 'Email（可空白）'); Department = (Read-Choice '部門（可空白）'); Title = (Read-Choice '職稱（可空白）')
        Company = ''; Office = ''; OfficePhone = (Read-Choice '電話（可空白）'); MobilePhone = ''; EmployeeID = (Read-Choice '員工編號（可空白）')
        Manager = (Read-Choice '主管帳號（可空白）'); Description = (Read-Choice '描述（可空白）'); Info = (Read-Choice '附註（可空白）')
        AccountExpirationDate = (Read-Choice '帳號到期日（例如 2026-12-31，可空白）'); Enabled = '是'
        MemberOf = (Read-Choice '要加入的群組（多個用 ; 分隔，可空白）')
    }
    $pw = Read-InitialPassword
    if (-not $pw) { Write-Status '已取消。' -Level Hint; return }
    $plan = New-ChangePlan -UserRows @($row) -Password $pw
    [void](Invoke-PlanReview -Plan $plan -Password $pw -Title '新增使用者')
}

function Invoke-AddMemberForm {
    Write-Section '加入成員到群組'
    $g = Select-GroupInteractive
    if (-not $g) { return }
    $text = Read-Choice "要加入「$($g.Name)」的成員（帳號、群組或電腦名稱，多個用 ; 分隔）"
    $names = Split-NameList $text
    if ($names.Count -eq 0) { return }
    $rows = @(foreach ($n in $names) { [pscustomobject]@{ Source = '手動輸入'; Group = $g.SamAccountName; Member = $n } })
    $plan = New-ChangePlan -AddMemberRows $rows
    [void](Invoke-PlanReview -Plan $plan -Title "加入成員到 $($g.Name)")
}

function Invoke-RemoveMemberForm {
    Write-Section '從群組移除成員'
    $g = Select-GroupInteractive
    if (-not $g) { return }
    $members = @(Get-GroupMemberDetail -Identity $g.DistinguishedName)
    if ($members.Count -eq 0) { Write-Status "群組「$($g.Name)」沒有直接成員。" -Level Warn; return }
    Show-Table -Rows $members -Kind Member -Title "群組「$($g.Name)」的直接成員"
    $text = Read-Choice '要移除哪些成員？輸入編號（例如 1,3,5）或帳號（多個用 ; 分隔），直接按 Enter 取消'
    if (-not $text) { return }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($t in (Split-NameList $text)) {
        $n = 0
        if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le $members.Count) {
            $m = $members[$n - 1]
            $names.Add($(if ($m.SamAccountName) { $m.SamAccountName } else { $m.DistinguishedName }))
        }
        else { $names.Add($t) }
    }
    $rows = @(foreach ($n in $names) { [pscustomobject]@{ Source = '手動輸入'; Group = $g.SamAccountName; Member = $n } })
    $plan = New-ChangePlan -RemoveMemberRows $rows
    [void](Invoke-PlanReview -Plan $plan -Title "從 $($g.Name) 移除成員")
}

function Invoke-MoveForm {
    Write-Section '搬移物件到其他 OU'
    $text = Read-Field -Label '要搬移的物件（帳號、電腦名稱、名稱或 DN，多個用 ; 分隔）' -Required
    $names = Split-NameList $text
    if ($names.Count -eq 0) { return }
    $tgt = Read-OU -Kind '搬移'
    if (-not $tgt) { return }
    $rows = @(foreach ($n in $names) { [pscustomobject]@{ Source = '手動輸入'; Object = $n; SourceOU = ''; TargetOU = $tgt } })
    $plan = New-ChangePlan -MoveRows $rows
    [void](Invoke-PlanReview -Plan $plan -Title '搬移物件')
}

function Read-FilePath {
    param([string]$Prompt, [string]$Default = '')
    $hint = if ($Default) { "（直接按 Enter = $Default）" } else { '（直接按 Enter 返回）' }
    $p = (Read-Choice "$Prompt$hint").Trim('"')
    if (-not $p) { $p = $Default }
    if (-not $p) { return $null }
    if (-not (Test-Path -LiteralPath $p)) { Write-Status "找不到檔案：$p" -Level Error; return $null }
    return $p
}

function Invoke-ImportMenu {
    Write-Section '從 Excel / CSV 批次匯入'
    Write-Status 'Excel 可包含「群組」「使用者」「群組成員」「移除成員」「搬移」工作表（可用 [7] 產生範本）；CSV 一次一種資料。' -Level Hint
    $path = Read-FilePath -Prompt '請輸入檔案路徑（.xlsx 或 .csv，可直接把檔案拖進視窗）'
    if (-not $path) { return }
    try { $book = Import-Spreadsheet -Path $path }
    catch { Write-Status "讀取失敗：$($_.Exception.Message)" -Level Error; return }

    $data = @{ Group = @(); User = @(); AddMember = @(); RemoveMember = @(); Move = @() }
    $fieldKind = @{ Group = 'Group'; User = 'User'; AddMember = 'Membership'; RemoveMember = 'Membership'; Move = 'Move' }
    $kindText = @{ Group = '新增群組'; User = '新增使用者'; AddMember = '加入成員'; RemoveMember = '移除成員'; Move = '搬移物件' }
    foreach ($sheet in $book.Keys) {
        $rows = @($book[$sheet])
        $kind = Get-SheetKind $sheet
        if ($sheet -eq 'CSV') {
            $c = Read-Choice 'CSV 的內容是：[1] 群組  [2] 使用者  [3] 加入成員  [4] 移除成員  [5] 搬移物件'
            $kind = switch ($c) { '1' { 'Group' } '2' { 'User' } '3' { 'AddMember' } '4' { 'RemoveMember' } '5' { 'Move' } default { $null } }
            if (-not $kind) { Write-Status '已取消。' -Level Hint; return }
        }
        if (-not $kind) {
            if ($rows.Count -gt 0) { Write-Status "工作表「$sheet」不是匯入用的工作表，略過。" -Level Hint }
            continue
        }
        if ($rows.Count -eq 0) { continue }
        $conv = ConvertTo-FieldRows -Rows $rows -Kind $fieldKind[$kind] -SheetName $sheet
        $data[$kind] = @($data[$kind]) + @($conv.Rows)
        Write-Status "工作表「$sheet」：$($rows.Count) 列（$($kindText[$kind])）" -Level Info
        if ($conv.Unknown.Count -gt 0) { Write-Status "工作表「$sheet」有無法辨識的欄位，會被忽略：$($conv.Unknown -join '、')" -Level Warn }
    }
    $total = $data.Group.Count + $data.User.Count + $data.AddMember.Count + $data.RemoveMember.Count + $data.Move.Count
    if ($total -eq 0) { Write-Status '檔案中沒有可以匯入的資料。' -Level Warn; return }

    $defaultOU = ''
    $needOU = @(@($data.Group) + @($data.User) | Where-Object { -not $_.Path }).Count
    if ($needOU -gt 0) {
        $defaultOU = Read-Choice "有 $needOU 列沒有填 OU，要使用哪個預設 OU？（例如 台北/財務部/帳號，或完整的 DN；直接按 Enter 表示不指定，這些列會顯示錯誤）"
    }
    $pw = $null
    if ($data.User.Count -gt 0) {
        $pw = Read-InitialPassword
        if (-not $pw) { Write-Status '沒有輸入初始密碼，已取消。' -Level Hint; return }
    }
    Write-Status '檢查資料中（只會查詢 AD，不會修改）...' -Level Info
    try {
        $plan = New-ChangePlan -GroupRows $data.Group -UserRows $data.User -AddMemberRows $data.AddMember -RemoveMemberRows $data.RemoveMember -MoveRows $data.Move -Password $pw -DefaultOU $defaultOU
    }
    catch { Write-Status "建立預覽失敗：$($_.Exception.Message)" -Level Error; return }
    [void](Invoke-PlanReview -Plan $plan -Password $pw -Title "批次匯入：$(Split-Path $path -Leaf)")
}

function Invoke-TemplateMenu {
    $def = Join-Path (Get-DefaultExportFolder) 'AD匯入範本.xlsx'
    $p = (Read-Choice "範本要存到哪裡？（直接按 Enter = $def）").Trim('"')
    if (-not $p) { $p = $def }
    if ([System.IO.Path]::GetExtension($p) -ne '.xlsx') { $p += '.xlsx' }
    if ((Test-Path -LiteralPath $p) -and -not (Read-YesNo -Prompt "檔案已存在，要覆蓋嗎？" -Default $false)) { return }
    $dn = 'DC=corp,DC=local'
    $srv = Get-ADServerParam
    try { $dn = [string](Get-ADDomain @srv -ErrorAction Stop).DistinguishedName } catch { Write-Verbose '讀取網域名稱失敗，範本使用範例網域' }
    try {
        $f = New-ImportTemplate -Path $p -DomainDN $dn
        Write-Status "已產生範本：$f" -Level Ok
        Write-Status '範本中的範例資料請改成實際資料，不需要的列刪除即可。' -Level Hint
    }
    catch { Write-Status "產生範本失敗：$($_.Exception.Message)" -Level Error }
}

function Invoke-UndoMenu {
    Write-Section '用還原清單復原'
    Write-Status '還原清單是每次執行後自動產生的 CSV（檔名：還原清單_日期時間.csv）。' -Level Hint
    $path = Read-FilePath -Prompt '請輸入還原清單路徑' -Default $script:Mgmt.LastUndoPath
    if (-not $path) { return }
    try { $plan = New-UndoPlan -Path $path }
    catch { Write-Status "讀取還原清單失敗：$($_.Exception.Message)" -Level Error; return }
    if ($plan.Count -eq 0) { Write-Status '還原清單是空的。' -Level Warn; return }
    [void](Invoke-PlanReview -Plan $plan -Title '復原變更')
}

function Show-ManagementMenu {
    Write-Section '管理（會修改 AD；每個動作都會先預覽，輸入 YES 才執行）'
    $items = @(
        [pscustomobject]@{ Key = '1'; Label = '新增群組'; Hint = '單筆輸入' }
        [pscustomobject]@{ Key = '2'; Label = '新增使用者'; Hint = '單筆輸入' }
        [pscustomobject]@{ Key = '3'; Label = '加入成員到群組'; Hint = '使用者、群組或電腦' }
        [pscustomobject]@{ Key = '4'; Label = '從群組移除成員'; Hint = '從目前成員中挑選' }
        [pscustomobject]@{ Key = '5'; Label = '搬移物件到其他 OU'; Hint = '使用者、群組、電腦；自動查出目前位置' }
        [pscustomobject]@{ Key = '6'; Label = '從 Excel 批次匯入'; Hint = '群組、使用者、加入 / 移除成員、搬移（.xlsx / .csv）' }
        [pscustomobject]@{ Key = '7'; Label = '產生 Excel 範本'; Hint = '含欄位說明與範例' }
        [pscustomobject]@{ Key = '8'; Label = '用還原清單復原'; Hint = '復原先前執行的變更' }
        [pscustomobject]@{ Key = 'Q'; Label = '返回上一層'; Hint = '' }
    )
    foreach ($it in $items) {
        Write-Host '  [' -NoNewline
        Write-Host $it.Key -NoNewline -ForegroundColor Yellow
        Write-Host ('] ' + (Format-Cell $it.Label 20)) -NoNewline
        Write-Host $it.Hint -ForegroundColor DarkGray
    }
}

function Start-ADManagement {
    <#
    .SYNOPSIS
        互動式管理選單（會修改 AD）。所有動作都先預覽，確認後輸入 YES 才執行。
    #>
    [CmdletBinding()]
    param()
    if (-not (Test-ADModuleAvailable)) { return }
    Write-Host ''
    Write-Status '注意：管理功能會修改 AD，需要有建立物件 / 修改群組成員 / 搬移物件的權限。' -Level Warn
    while ($true) {
        Show-ManagementMenu
        $c = (Read-Choice '請選擇').ToUpperInvariant()
        try {
            switch ($c) {
                '1' { Invoke-NewGroupForm }
                '2' { Invoke-NewUserForm }
                '3' { Invoke-AddMemberForm }
                '4' { Invoke-RemoveMemberForm }
                '5' { Invoke-MoveForm }
                '6' { Invoke-ImportMenu }
                '7' { Invoke-TemplateMenu }
                '8' { Invoke-UndoMenu }
                'Q' { return }
                default { Write-Status '請輸入選單上的代號。' -Level Warn }
            }
        }
        catch { Write-Status "發生錯誤：$($_.Exception.Message)" -Level Error }
    }
}

function Start-ADTool {
    <#
    .SYNOPSIS
        最上層選單：[1] 查詢（唯讀）  [2] 管理（會修改 AD）。
    #>
    [CmdletBinding()]
    param([string]$Path)
    $bar = '=' * 52
    Write-Host ''
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host '    AD 權限查詢與管理工具' -ForegroundColor Cyan
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host '    查詢功能唯讀；管理功能會修改 AD，執行前一律先預覽' -ForegroundColor DarkGray
    if (-not (Test-ADModuleAvailable)) { return }
    if ($Path) { Start-ADPermissionQuery -Path $Path -Embedded }
    while ($true) {
        Write-Section '請選擇功能'
        $top = @(
            [pscustomobject]@{ Key = '1'; Label = '查詢（唯讀）'; Hint = '路徑權限、群組成員、使用者 / 電腦資訊、比較群組...' }
            [pscustomobject]@{ Key = '2'; Label = '管理（會修改 AD）'; Hint = '新增群組 / 使用者、加入 / 移除成員、搬移 OU、Excel 匯入' }
            [pscustomobject]@{ Key = 'Q'; Label = '離開'; Hint = '' }
        )
        foreach ($it in $top) {
            Write-Host '  [' -NoNewline
            Write-Host $it.Key -NoNewline -ForegroundColor Yellow
            Write-Host ('] ' + (Format-Cell $it.Label 20)) -NoNewline
            Write-Host $it.Hint -ForegroundColor DarkGray
        }
        $c = (Read-Choice '請選擇').ToUpperInvariant()
        switch ($c) {
            '1' { Start-ADPermissionQuery -Embedded }
            '2' { Start-ADManagement }
            'Q' { return }
            default { Write-Status '請輸入選單上的代號。' -Level Warn }
        }
    }
}

Export-ModuleMember -Function Start-ADTool, Start-ADManagement, New-ChangePlan, New-UndoPlan, Invoke-PlanReview,
Import-Spreadsheet, New-ImportTemplate, ConvertTo-FieldRows
