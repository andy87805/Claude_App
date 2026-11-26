#Requires -Version 5.1
<#
    ADPermissionQuery.psm1
    資料夾 / 共用路徑權限查詢工具（AD 環境用）

    ★ 本模組「只讀」：
      - 只使用 Get-Acl、Get-ChildItem、Get-AD* 等查詢指令，不會修改 AD、群組、帳號或任何 NTFS 權限。
      - 唯一會寫入的是「本機」上的查詢紀錄 log 檔與使用者主動匯出的 CSV / HTML 報表。
      - tests\ReadOnly.Tests.ps1 會掃描本檔所有指令與方法呼叫，確保沒有任何異動類指令。
#>

# ---------------------------------------------------------------------------
# 模組設定
# ---------------------------------------------------------------------------
$script:Config = @{
    Server       = $null      # 指定網域控制站（可留空，自動找）
    InactiveDays = 90         # 超過幾天未登入視為「久未登入」
    LogPath      = $null      # 查詢紀錄檔路徑
    NoLog        = $false
    NoGui        = $false     # 強制不用 Out-GridView
}
$script:IdentityCache = @{}
$script:UserCache     = @{}

# 內建 / 特殊帳戶（這些不是 AD 物件，無法展開成員）
$script:WellKnownSids = @{
    'S-1-1-0'      = 'Everyone（所有人）'
    'S-1-3-0'      = 'CREATOR OWNER（建立者擁有者）'
    'S-1-3-1'      = 'CREATOR GROUP（建立者群組）'
    'S-1-5-2'      = 'NETWORK（網路登入）'
    'S-1-5-4'      = 'INTERACTIVE（互動式登入）'
    'S-1-5-7'      = 'ANONYMOUS LOGON（匿名登入）'
    'S-1-5-9'      = 'Enterprise Domain Controllers'
    'S-1-5-10'     = 'SELF'
    'S-1-5-11'     = 'Authenticated Users（已驗證的使用者）'
    'S-1-5-18'     = 'SYSTEM'
    'S-1-5-19'     = 'LOCAL SERVICE'
    'S-1-5-20'     = 'NETWORK SERVICE'
    'S-1-5-32-544' = 'BUILTIN\Administrators（本機系統管理員）'
    'S-1-5-32-545' = 'BUILTIN\Users（本機使用者）'
    'S-1-5-32-546' = 'BUILTIN\Guests'
    'S-1-5-32-547' = 'BUILTIN\Power Users'
    'S-1-5-32-549' = 'BUILTIN\Server Operators'
    'S-1-5-32-551' = 'BUILTIN\Backup Operators'
}
$script:BuiltinPrefixes = @('BUILTIN\', 'NT AUTHORITY\', 'NT SERVICE\', 'APPLICATION PACKAGE AUTHORITY\', 'CREATOR ', 'EVERYONE')

# ---------------------------------------------------------------------------
# 一般工具函式
# ---------------------------------------------------------------------------
function Set-ADPermissionQueryOption {
    <# 設定模組選項（只改本工具在記憶體中的設定，不碰 AD） #>
    [CmdletBinding()]
    param(
        [string]$Server,
        [int]$InactiveDays,
        [string]$LogPath,
        [switch]$NoLog,
        [switch]$NoGui
    )
    if ($PSBoundParameters.ContainsKey('Server'))       { $script:Config.Server = $Server }
    if ($PSBoundParameters.ContainsKey('InactiveDays')) { $script:Config.InactiveDays = $InactiveDays }
    if ($PSBoundParameters.ContainsKey('LogPath'))      { $script:Config.LogPath = $LogPath }
    if ($PSBoundParameters.ContainsKey('NoLog'))        { $script:Config.NoLog = [bool]$NoLog }
    if ($PSBoundParameters.ContainsKey('NoGui'))        { $script:Config.NoGui = [bool]$NoGui }
    $script:IdentityCache = @{}
    $script:UserCache = @{}
}

function Get-ADServerParam {
    # 回傳要 splat 給 Get-AD* 的參數
    $p = @{}
    if ($script:Config.Server) { $p['Server'] = $script:Config.Server }
    return $p
}

function ConvertTo-LdapFilterValue {
    # 給 -Filter 字串使用的跳脫（單引號重複）
    param([string]$Value)
    return ($Value -replace "'", "''")
}

function Get-DefaultLogPath {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $base 'ADPermissionQuery') 'query.log')
}

function Write-QueryLog {
    <# 把查詢動作寫到本機 log 檔（只寫本機檔案，不碰 AD） #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [string]$Target = ''
    )
    if ($script:Config.NoLog) { return }
    try {
        $path = $script:Config.LogPath
        if (-not $path) { $path = Get-DefaultLogPath }
        $dir = Split-Path -Path $path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $operator = if ($env:USERDOMAIN) { "$($env:USERDOMAIN)\$($env:USERNAME)" } else { "$env:USERNAME" }
        if (-not $operator.Trim('\')) { $operator = [Environment]::UserName }
        $line = "{0}`t{1}`t{2}`t{3}`t{4}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $operator, [Environment]::MachineName, $Action, $Target
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    }
    catch {
        Write-Verbose "寫入查詢紀錄失敗：$($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 權限文字轉換
# ---------------------------------------------------------------------------
function Convert-FileSystemRight {
    <# 把 FileSystemRights 數值轉成中文說明 #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rights)

    [int64]$v = [int64]$Rights
    if ($v -lt 0) { $v += 4294967296 }   # 轉成無號數

    # 通用權限（GENERIC_*，常見於 CREATOR OWNER 這類「只套用到子物件」的項目）
    [int64]$mask = $v -band 0x0FFFFFFF
    if ($v -band 0x10000000) { $mask = $mask -bor 0x1F01FF }   # GENERIC_ALL
    if ($v -band 0x20000000) { $mask = $mask -bor 0x1200A0 }   # GENERIC_EXECUTE
    if ($v -band 0x40000000) { $mask = $mask -bor 0x120116 }   # GENERIC_WRITE
    if ($v -band 0x80000000) { $mask = $mask -bor 0x120089 }   # GENERIC_READ

    $FullControl    = 0x1F01FF
    $Modify         = 0x1301BF
    $ReadAndExecute = 0x1200A9
    $Read           = 0x120089
    $Write          = 0x000116
    $Sync           = 0x100000

    if (($mask -band $FullControl) -eq $FullControl) { return '完全控制' }

    $names = New-Object System.Collections.Generic.List[string]
    [int64]$covered = $Sync
    if (($mask -band $Modify) -eq $Modify) {
        $names.Add('修改'); $covered = $covered -bor $Modify
    }
    else {
        if (($mask -band $ReadAndExecute) -eq $ReadAndExecute) {
            $names.Add('讀取和執行'); $covered = $covered -bor $ReadAndExecute
        }
        elseif (($mask -band $Read) -eq $Read) {
            $names.Add('讀取'); $covered = $covered -bor $Read
        }
        if (($mask -band $Write) -eq $Write) {
            $names.Add('寫入'); $covered = $covered -bor $Write -bor 0x20000
        }
    }
    $rest = $mask -band (-bnot $covered) -band 0x1F01FF
    if ($rest -ne 0) {
        $names.Add(('特殊權限(0x{0:X})' -f $rest))
    }
    if ($names.Count -eq 0) { return ('特殊權限(0x{0:X})' -f $v) }
    return ($names -join '、')
}

function Convert-InheritanceToText {
    <# 把繼承旗標轉成「套用到」的中文說明 #>
    param($InheritanceFlags, $PropagationFlags)
    $i = [int]$InheritanceFlags
    $p = [int]$PropagationFlags
    $inheritOnly = ($p -band 2) -ne 0
    $noPropagate = ($p -band 1) -ne 0
    $text = switch ($i) {
        0 { '只有此資料夾' }
        1 { if ($inheritOnly) { '只有子資料夾' } else { '此資料夾及子資料夾' } }
        2 { if ($inheritOnly) { '只有檔案' } else { '此資料夾及檔案' } }
        3 { if ($inheritOnly) { '只有子資料夾及檔案' } else { '此資料夾、子資料夾及檔案' } }
        default { "旗標 $i/$p" }
    }
    if ($noPropagate -and $i -ne 0) { $text += '（僅下一層）' }
    return $text
}

# ---------------------------------------------------------------------------
# ACL 讀取與身分解析
# ---------------------------------------------------------------------------
function ConvertTo-SidString {
    param([string]$Identity)
    if (-not $Identity) { return $null }
    if ($Identity -match '^S-1-[0-9-]+$') { return $Identity }
    try {
        $nt = New-Object System.Security.Principal.NTAccount($Identity)
        return $nt.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch { return $null }
}

function Get-PathAclInfo {
    <# 讀取路徑的 ACL（Get-Acl，唯讀），並整理出每一筆權限項目的名稱與 SID #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $nameRules = @($acl.Access)
    $sidRules = @()
    try {
        $sidRules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    }
    catch { $sidRules = @() }

    $rules = for ($i = 0; $i -lt $nameRules.Count; $i++) {
        $r = $nameRules[$i]
        $identity = [string]$r.IdentityReference
        $sid = $null
        if ($sidRules.Count -eq $nameRules.Count) { $sid = [string]$sidRules[$i].IdentityReference }
        if (-not $sid) { $sid = ConvertTo-SidString -Identity $identity }
        [pscustomobject]@{
            Identity          = $identity
            Sid               = $sid
            Rights            = $r.FileSystemRights
            AccessControlType = [string]$r.AccessControlType
            IsInherited       = [bool]$r.IsInherited
            InheritanceFlags  = $r.InheritanceFlags
            PropagationFlags  = $r.PropagationFlags
        }
    }

    [pscustomobject]@{
        Path                    = $Path
        Owner                   = [string]$acl.Owner
        AreAccessRulesProtected = [bool]$acl.AreAccessRulesProtected
        Rules                   = @($rules)
    }
}

function Resolve-AclIdentity {
    <# 把 ACL 上的帳戶名稱 / SID 對應到 AD 物件（唯讀查詢 Get-ADObject） #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [string]$Sid
    )
    $key = "$Identity|$Sid"
    if ($script:IdentityCache.ContainsKey($key)) { return $script:IdentityCache[$key] }

    $result = [pscustomobject]@{
        Identity          = $Identity
        Sid               = $Sid
        Category          = '未知'
        ObjectClass       = ''
        DisplayName       = ''
        SamAccountName    = ''
        DistinguishedName = ''
        Description       = ''
        CanExpand         = $false
        Note              = ''
    }

    $upper = $Identity.ToUpperInvariant()
    $isBuiltin = $false
    if ($Sid -and $script:WellKnownSids.ContainsKey($Sid)) { $isBuiltin = $true; $result.DisplayName = $script:WellKnownSids[$Sid] }
    elseif ($Sid -and ($Sid -like 'S-1-5-32-*' -or $Sid -like 'S-1-5-80-*' -or $Sid -like 'S-1-15-*')) { $isBuiltin = $true }
    else {
        foreach ($p in $script:BuiltinPrefixes) {
            if ($upper.StartsWith($p) -or $upper -eq $p.TrimEnd('\')) { $isBuiltin = $true; break }
        }
    }

    if ($isBuiltin) {
        $result.Category = '內建/特殊帳戶'
        $result.Note = '不是 AD 物件；若為本機群組，成員請在該伺服器上查看'
        $script:IdentityCache[$key] = $result
        return $result
    }

    $props = @('objectClass', 'sAMAccountName', 'displayName', 'name', 'objectSid', 'description', 'distinguishedName')
    $srv = Get-ADServerParam
    $obj = $null
    try {
        if ($Sid -and $Sid -like 'S-1-5-21-*') {
            $obj = Get-ADObject -Filter "objectSid -eq '$(ConvertTo-LdapFilterValue $Sid)'" -Properties $props @srv -ErrorAction Stop | Select-Object -First 1
        }
        # 已知 SID 卻查不到時不再用名稱查詢，避免把伺服器本機帳戶誤對應到同名的 AD 帳號
        if (-not $obj -and -not $Sid -and $Identity -notmatch '^S-1-') {
            $sam = $Identity
            if ($sam.Contains('\')) { $sam = $sam.Substring($sam.IndexOf('\') + 1) }
            $obj = Get-ADObject -Filter "sAMAccountName -eq '$(ConvertTo-LdapFilterValue $sam)'" -Properties $props @srv -ErrorAction Stop | Select-Object -First 1
        }
    }
    catch {
        $result.Note = "AD 查詢失敗：$($_.Exception.Message)"
    }

    if ($obj) {
        $cls = [string](@($obj.objectClass)[-1])
        $result.ObjectClass = $cls
        $result.SamAccountName = [string]$obj.sAMAccountName
        $result.DisplayName = if ($obj.displayName) { [string]$obj.displayName } else { [string]$obj.name }
        $result.DistinguishedName = [string]$obj.distinguishedName
        $result.Description = [string]$obj.description
        if ($obj.objectSid -and -not $result.Sid) { $result.Sid = [string]$obj.objectSid }
        switch ($cls) {
            'group'                            { $result.Category = '群組'; $result.CanExpand = $true }
            'user'                             { $result.Category = '使用者' }
            'inetOrgPerson'                    { $result.Category = '使用者' }
            'computer'                         { $result.Category = '電腦' }
            'msDS-GroupManagedServiceAccount'  { $result.Category = '服務帳戶' }
            'msDS-ManagedServiceAccount'       { $result.Category = '服務帳戶' }
            'foreignSecurityPrincipal'         { $result.Category = '外部安全主體' }
            default                            { $result.Category = $cls }
        }
    }
    elseif (-not $result.Note) {
        if (($Identity -match '^S-1-5-21-') -or (-not $Identity)) {
            $result.Category = '孤立 SID'
            $result.Note = '找不到對應帳戶，可能已被刪除（建議清理）'
        }
        else {
            $result.Category = '本機或其他網域帳戶'
            $result.Note = '在目前網域中找不到；可能是伺服器本機帳戶或信任網域帳戶'
        }
    }

    $script:IdentityCache[$key] = $result
    return $result
}

function Get-PathPermission {
    <#
    .SYNOPSIS
        查詢資料夾 / 共用路徑上有哪些人員或群組有權限（唯讀）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $info = Get-PathAclInfo -Path $Path
    $perms = foreach ($r in $info.Rules) {
        $id = Resolve-AclIdentity -Identity $r.Identity -Sid $r.Sid
        [pscustomobject]@{
            Identity          = $r.Identity
            DisplayName       = $id.DisplayName
            Category          = $id.Category
            Rights            = Convert-FileSystemRight -Rights $r.Rights
            AccessType        = if ($r.AccessControlType -eq 'Deny') { '拒絕' } else { '允許' }
            AppliesTo         = Convert-InheritanceToText -InheritanceFlags $r.InheritanceFlags -PropagationFlags $r.PropagationFlags
            IsInherited       = $r.IsInherited
            Note              = $id.Note
            Sid               = if ($id.Sid) { $id.Sid } else { $r.Sid }
            SamAccountName    = $id.SamAccountName
            DistinguishedName = $id.DistinguishedName
            CanExpand         = $id.CanExpand
        }
    }
    Write-QueryLog -Action '查詢路徑權限' -Target $Path

    [pscustomobject]@{
        Path                    = $Path
        Owner                   = $info.Owner
        AreAccessRulesProtected = $info.AreAccessRulesProtected
        Permissions             = @($perms)
    }
}

# ---------------------------------------------------------------------------
# 群組成員
# ---------------------------------------------------------------------------
function Get-UserStatusText {
    param($User, [int]$InactiveDays)
    $flags = New-Object System.Collections.Generic.List[string]
    if ($User.Enabled -eq $false) { $flags.Add('停用') }
    if ($User.LockedOut -eq $true) { $flags.Add('鎖定') }
    if ($User.PasswordExpired -eq $true) { $flags.Add('密碼已過期') }
    if ($User.LastLogonDate) {
        $days = ((Get-Date) - [datetime]$User.LastLogonDate).Days
        if ($days -gt $InactiveDays) { $flags.Add("超過 $InactiveDays 天未登入") }
    }
    elseif ($User.Enabled -ne $false) { $flags.Add('從未登入') }
    if ($flags.Count -eq 0) { return '正常' }
    return ($flags -join '、')
}

function Get-ADUserDetail {
    <# 取得使用者詳細資料（Get-ADUser，唯讀） #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Identity)
    if ($script:UserCache.ContainsKey($Identity)) { return $script:UserCache[$Identity] }
    $props = @('DisplayName', 'Department', 'Title', 'mail', 'telephoneNumber', 'Office', 'Company', 'Description',
        'Enabled', 'LockedOut', 'PasswordExpired', 'PasswordNeverExpires', 'PasswordLastSet', 'LastLogonDate', 'whenCreated')
    $srv = Get-ADServerParam
    $u = Get-ADUser -Identity $Identity -Properties $props @srv -ErrorAction Stop
    $script:UserCache[$Identity] = $u
    return $u
}

function Get-GroupMemberDetail {
    <#
    .SYNOPSIS
        列出群組成員與其資訊（唯讀）。-Recurse 會展開巢狀群組並標示取得途徑。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [switch]$Recurse
    )
    $srv = Get-ADServerParam
    $root = Get-ADGroup -Identity $Identity @srv -ErrorAction Stop
    $inactiveDays = $script:Config.InactiveDays

    $results = New-Object System.Collections.Generic.List[object]
    $userIndex = @{}                                   # DN -> 結果列（同一人經多條途徑時合併）
    $visited = New-Object System.Collections.Generic.HashSet[string]

    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@{ Group = $root; Chain = @([string]$root.Name) })
    [void]$visited.Add([string]$root.DistinguishedName)

    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $group = $item.Group
        $chain = $item.Chain
        $via = $chain -join ' > '

        $members = @()
        try {
            $members = @(Get-ADGroupMember -Identity $group.DistinguishedName @srv -ErrorAction Stop)
        }
        catch {
            Write-Warning "群組「$($group.Name)」用 Get-ADGroupMember 讀取失敗（$($_.Exception.Message)），改用 member 屬性讀取（不含以主要群組加入的成員）。"
            try {
                $g = Get-ADGroup -Identity $group.DistinguishedName -Properties member @srv -ErrorAction Stop
                $members = @(foreach ($dn in @($g.member)) {
                        Get-ADObject -Identity $dn -Properties objectClass, sAMAccountName, name, objectSid @srv -ErrorAction SilentlyContinue
                    })
            }
            catch {
                Write-Warning "群組「$($group.Name)」成員無法讀取：$($_.Exception.Message)"
            }
        }

        foreach ($m in $members) {
            if (-not $m) { continue }
            $cls = [string](@($m.objectClass)[-1])
            $dn = [string]$m.distinguishedName

            if ($cls -eq 'group') {
                $results.Add([pscustomobject]@{
                        Name = [string]$m.name; SamAccountName = [string]$m.SamAccountName; ObjectClass = '群組'
                        Department = ''; Title = ''; Email = ''; Phone = ''; Office = ''
                        Enabled = $null; Status = '（巢狀群組）'; LastLogonDate = $null; PasswordLastSet = $null
                        PasswordNeverExpires = $null; Via = $via; DistinguishedName = $dn
                    })
                if ($Recurse -and $visited.Add($dn)) {
                    $queue.Enqueue(@{ Group = $m; Chain = @($chain + [string]$m.name) })
                }
                elseif ($Recurse) {
                    Write-Verbose "略過已展開過的群組（避免循環）：$dn"
                }
                continue
            }

            if ($cls -eq 'user' -or $cls -eq 'inetOrgPerson') {
                if ($userIndex.ContainsKey($dn)) {
                    $existing = $userIndex[$dn]
                    if (($existing.Via -split '；') -notcontains $via) { $existing.Via = "$($existing.Via)；$via" }
                    continue
                }
                $u = $null
                try { $u = Get-ADUserDetail -Identity $dn } catch { Write-Warning "讀取使用者 $dn 失敗：$($_.Exception.Message)" }
                if ($u) {
                    $row = [pscustomobject]@{
                        Name                 = if ($u.DisplayName) { [string]$u.DisplayName } else { [string]$u.Name }
                        SamAccountName       = [string]$u.SamAccountName
                        ObjectClass          = '使用者'
                        Department           = [string]$u.Department
                        Title                = [string]$u.Title
                        Email                = [string]$u.mail
                        Phone                = [string]$u.telephoneNumber
                        Office               = [string]$u.Office
                        Enabled              = $u.Enabled
                        Status               = Get-UserStatusText -User $u -InactiveDays $inactiveDays
                        LastLogonDate        = $u.LastLogonDate
                        PasswordLastSet      = $u.PasswordLastSet
                        PasswordNeverExpires = $u.PasswordNeverExpires
                        Via                  = $via
                        DistinguishedName    = $dn
                    }
                }
                else {
                    $row = [pscustomobject]@{
                        Name = [string]$m.name; SamAccountName = [string]$m.SamAccountName; ObjectClass = '使用者'
                        Department = ''; Title = ''; Email = ''; Phone = ''; Office = ''
                        Enabled = $null; Status = '無法讀取詳細資料'; LastLogonDate = $null; PasswordLastSet = $null
                        PasswordNeverExpires = $null; Via = $via; DistinguishedName = $dn
                    }
                }
                $userIndex[$dn] = $row
                $results.Add($row)
                continue
            }

            # 電腦、服務帳戶、外部安全主體等
            $typeName = switch ($cls) {
                'computer'                        { '電腦' }
                'msDS-GroupManagedServiceAccount' { '服務帳戶' }
                'msDS-ManagedServiceAccount'      { '服務帳戶' }
                'foreignSecurityPrincipal'        { '外部安全主體' }
                default                           { $cls }
            }
            $results.Add([pscustomobject]@{
                    Name = [string]$m.name; SamAccountName = [string]$m.SamAccountName; ObjectClass = $typeName
                    Department = ''; Title = ''; Email = ''; Phone = ''; Office = ''
                    Enabled = $null; Status = ''; LastLogonDate = $null; PasswordLastSet = $null
                    PasswordNeverExpires = $null; Via = $via; DistinguishedName = $dn
                })
        }
    }

    Write-QueryLog -Action ('查詢群組成員' + $(if ($Recurse) { '(含巢狀)' } else { '' })) -Target ([string]$root.Name)
    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# 反查使用者權限
# ---------------------------------------------------------------------------
function Find-UserPathAccess {
    <#
    .SYNOPSIS
        反查某位使用者在路徑上透過哪些項目取得權限（唯讀，使用 tokenGroups）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$User,
        $PermissionResult
    )
    if (-not $PermissionResult) { $PermissionResult = Get-PathPermission -Path $Path }

    $sam = $User
    if ($sam.Contains('\')) { $sam = $sam.Substring($sam.IndexOf('\') + 1) }
    if ($sam.Contains('@')) { $sam = $sam.Substring(0, $sam.IndexOf('@')) }

    $srv = Get-ADServerParam
    $u = Get-ADUser -Identity $sam -Properties tokenGroups, DisplayName @srv -ErrorAction Stop

    $userSid = [string]$u.SID
    $groupSids = New-Object System.Collections.Generic.HashSet[string]
    foreach ($g in @($u.tokenGroups)) { [void]$groupSids.Add([string]$g) }

    $matched = foreach ($p in $PermissionResult.Permissions) {
        $sid = [string]$p.Sid
        $reason = $null; $certainty = $null
        if ($sid -and $sid -eq $userSid)            { $reason = '使用者本人';                 $certainty = '確定' }
        elseif ($sid -and $groupSids.Contains($sid)) { $reason = "群組成員（$($p.Identity)）";   $certainty = '確定' }
        elseif ($sid -eq 'S-1-1-0')                  { $reason = 'Everyone（所有人）';          $certainty = '確定' }
        elseif ($sid -eq 'S-1-5-11')                 { $reason = 'Authenticated Users';        $certainty = '確定' }
        elseif ($sid -like 'S-1-5-32-*')             { $reason = "本機內建群組（$($p.Identity)）"; $certainty = '需確認（本機群組成員無法由 AD 判斷）' }
        if ($reason) {
            [pscustomobject]@{
                User        = "$([string]$u.SamAccountName)（$([string]$u.DisplayName)）"
                MatchedBy   = $p.Identity
                Reason      = $reason
                Certainty   = $certainty
                Rights      = $p.Rights
                AccessType  = $p.AccessType
                AppliesTo   = $p.AppliesTo
                IsInherited = $p.IsInherited
            }
        }
    }
    Write-QueryLog -Action '反查使用者權限' -Target "$sam @ $Path"
    return @($matched)
}

# ---------------------------------------------------------------------------
# 子資料夾掃描
# ---------------------------------------------------------------------------
function Get-SubfolderPermissionDiff {
    <#
    .SYNOPSIS
        往下掃描子資料夾，只列出「中斷繼承」或「有額外明確權限」的資料夾（唯讀）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 20)][int]$Depth = 3
    )
    $errs = $null
    $dirs = @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Depth ($Depth - 1) -Force -ErrorAction SilentlyContinue -ErrorVariable errs)

    $rows = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($d in $dirs) {
        $i++
        Write-Progress -Activity '掃描子資料夾權限' -Status $d.FullName -PercentComplete ([int](100 * $i / [math]::Max(1, $dirs.Count)))
        try {
            $info = Get-PathAclInfo -Path $d.FullName
        }
        catch {
            $rows.Add([pscustomobject]@{ Folder = $d.FullName; InheritanceBroken = ''; Identity = ''; Category = ''; Rights = ''; AccessType = ''; AppliesTo = ''; Note = "無法讀取：$($_.Exception.Message)" })
            continue
        }
        $explicit = @($info.Rules | Where-Object { -not $_.IsInherited })
        if (-not $info.AreAccessRulesProtected -and $explicit.Count -eq 0) { continue }

        $broken = if ($info.AreAccessRulesProtected) { '是' } else { '否' }
        if ($explicit.Count -eq 0) {
            $rows.Add([pscustomobject]@{ Folder = $d.FullName; InheritanceBroken = $broken; Identity = ''; Category = ''; Rights = ''; AccessType = ''; AppliesTo = ''; Note = '已中斷繼承且沒有任何權限項目' })
            continue
        }
        foreach ($r in $explicit) {
            $id = Resolve-AclIdentity -Identity $r.Identity -Sid $r.Sid
            $rows.Add([pscustomobject]@{
                    Folder            = $d.FullName
                    InheritanceBroken = $broken
                    Identity          = $r.Identity
                    Category          = $id.Category
                    Rights            = Convert-FileSystemRight -Rights $r.Rights
                    AccessType        = if ($r.AccessControlType -eq 'Deny') { '拒絕' } else { '允許' }
                    AppliesTo         = Convert-InheritanceToText -InheritanceFlags $r.InheritanceFlags -PropagationFlags $r.PropagationFlags
                    Note              = $id.Note
                })
        }
    }
    Write-Progress -Activity '掃描子資料夾權限' -Completed
    foreach ($e in @($errs)) {
        if (-not $e) { continue }
        $target = if ($e.TargetObject) { [string]$e.TargetObject } else { '' }
        $rows.Add([pscustomobject]@{ Folder = $target; InheritanceBroken = ''; Identity = ''; Category = ''; Rights = ''; AccessType = ''; AppliesTo = ''; Note = "無法列出：$($e.Exception.Message)" })
    }
    Write-QueryLog -Action "掃描子資料夾(深度 $Depth)" -Target $Path
    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# 顯示、篩選、匯出
# ---------------------------------------------------------------------------
$script:ViewColumns = @{
    Permission = [ordered]@{ Identity = '帳戶'; DisplayName = '顯示名稱'; Category = '類型'; Rights = '權限'; AccessType = '允許/拒絕'; AppliesTo = '套用到'; IsInherited = '繼承'; Note = '備註' }
    Member     = [ordered]@{ Name = '姓名'; SamAccountName = '帳號'; ObjectClass = '類型'; Department = '部門'; Title = '職稱'; Email = 'Email'; Phone = '電話'; Status = '帳號狀態'; LastLogonDate = '最後登入'; PasswordLastSet = '密碼設定日'; Via = '取得途徑' }
    Access     = [ordered]@{ User = '使用者'; MatchedBy = '對應項目'; Reason = '取得原因'; Certainty = '確定性'; Rights = '權限'; AccessType = '允許/拒絕'; AppliesTo = '套用到'; IsInherited = '繼承' }
    Scan       = [ordered]@{ Folder = '資料夾'; InheritanceBroken = '中斷繼承'; Identity = '帳戶'; Category = '類型'; Rights = '權限'; AccessType = '允許/拒絕'; AppliesTo = '套用到'; Note = '備註' }
}

function Format-ForDisplay {
    <# 轉成中文欄位名稱的顯示物件，並加上 # 編號 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Permission', 'Member', 'Access', 'Scan')][string]$Kind,
        [AllowEmptyCollection()][object[]]$InputObject = @(),
        [switch]$NoIndex
    )
    $cols = $script:ViewColumns[$Kind]
    $n = 0
    foreach ($o in $InputObject) {
        $n++
        $h = [ordered]@{}
        if (-not $NoIndex) { $h['#'] = $n }
        foreach ($k in $cols.Keys) {
            $v = $o.$k
            if ($v -is [bool]) { $v = if ($v) { '是' } else { '否' } }
            elseif ($v -is [datetime]) { $v = $v.ToString('yyyy-MM-dd HH:mm') }
            $h[$cols[$k]] = $v
        }
        [pscustomobject]$h
    }
}

function Select-ByKeyword {
    <# 關鍵字篩選：任一欄位包含關鍵字即保留（不分大小寫，可用空白分隔多個關鍵字，需全部符合） #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$InputObject = @(),
        [string]$Keyword
    )
    if (-not $Keyword -or -not $Keyword.Trim()) { return $InputObject }
    $words = @($Keyword.Trim() -split '\s+')
    @(foreach ($o in $InputObject) {
            $text = (@($o.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join ' ')
            $ok = $true
            foreach ($w in $words) {
                if ($text.IndexOf($w, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false; break }
            }
            if ($ok) { $o }
        })
}

function Get-SafeFileName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() + [char[]]'\/:*?"<>|'
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Name.ToCharArray()) {
        if ($invalid -contains $c) { [void]$sb.Append('_') } else { [void]$sb.Append($c) }
    }
    $s = $sb.ToString().Trim(' ', '.', '_')
    if ($s.Length -gt 80) { $s = $s.Substring(0, 80) }
    if (-not $s) { $s = 'report' }
    return $s
}

function Get-DefaultExportFolder {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docs) { $docs = (Get-Location).Path }
    return (Join-Path $docs 'ADPermissionReports')
}

function Export-QueryReport {
    <#
    .SYNOPSIS
        把查詢結果匯出成 CSV（Excel 可直接開，含 BOM）及/或 HTML 報表。只寫入本機檔案。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Permission', 'Member', 'Access', 'Scan')][string]$Kind,
        [AllowEmptyCollection()][object[]]$InputObject = @(),
        [Parameter(Mandatory)][string]$Title,
        [ValidateSet('CSV', 'HTML', 'Both')][string]$Format = 'Both',
        [string]$Folder,
        [string]$Subtitle = ''
    )
    if (-not $Folder) { $Folder = Get-DefaultExportFolder }
    if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }

    $data = @(Format-ForDisplay -Kind $Kind -InputObject $InputObject -NoIndex)
    $base = Join-Path $Folder ('{0}_{1}' -f (Get-SafeFileName $Title), (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $files = @()

    if ($Format -eq 'CSV' -or $Format -eq 'Both') {
        $csv = "$base.csv"
        $enc = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
        if ($data.Count -gt 0) {
            $data | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding $enc
        }
        else {
            ($script:ViewColumns[$Kind].Values -join ',') | Out-File -LiteralPath $csv -Encoding $enc
        }
        $files += $csv
    }
    if ($Format -eq 'HTML' -or $Format -eq 'Both') {
        $html = "$base.html"
        $enc = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
        $css = @'
<meta charset="utf-8">
<style>
body{font-family:"Microsoft JhengHei","Segoe UI",sans-serif;margin:24px;color:#222}
h1{font-size:20px;margin:0 0 4px} p.sub{color:#666;margin:0 0 16px;font-size:13px}
table{border-collapse:collapse;font-size:13px;width:100%}
th{background:#2b579a;color:#fff;text-align:left;padding:6px 8px;position:sticky;top:0}
td{border-bottom:1px solid #ddd;padding:5px 8px;vertical-align:top}
tr:nth-child(even) td{background:#f5f7fa}
</style>
'@
        $enc2 = [System.Net.WebUtility]
        $pre = '<h1>{0}</h1><p class="sub">{1}產生時間：{2}　筆數：{3}</p>' -f $enc2::HtmlEncode($Title),
        $(if ($Subtitle) { $enc2::HtmlEncode($Subtitle) + '　' } else { '' }),
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $data.Count
        $props = @($script:ViewColumns[$Kind].Values)
        if ($data.Count -gt 0) {
            $content = $data | ConvertTo-Html -Property $props -Head $css -Title $Title -PreContent $pre
        }
        else {
            $content = ConvertTo-Html -Head $css -Title $Title -PreContent ($pre + '<p>（沒有資料）</p>')
        }
        $content | Out-File -LiteralPath $html -Encoding $enc
        $files += $html
    }
    Write-QueryLog -Action "匯出報表($Format)" -Target ($files -join ', ')
    return $files
}

# ---------------------------------------------------------------------------
# 互動式介面
# ---------------------------------------------------------------------------
function Test-GridViewAvailable {
    if ($script:Config.NoGui) { return $false }
    return [bool](Get-Command -Name Out-GridView -ErrorAction SilentlyContinue)
}

function Show-Table {
    <# 在主控台顯示表格 #>
    param([object[]]$Rows, [string]$Kind, [string]$Title)
    Write-Host ''
    if ($Title) { Write-Host "=== $Title ===" -ForegroundColor Cyan }
    if (-not $Rows -or $Rows.Count -eq 0) { Write-Host '（沒有資料）' -ForegroundColor DarkGray; return }
    Format-ForDisplay -Kind $Kind -InputObject $Rows | Format-Table -AutoSize -Wrap | Out-String -Width 4096 | Write-Host
}

function Select-OneItem {
    <#
        讓使用者從清單中選一筆：有 Out-GridView 用視窗（可排序、搜尋），否則用編號選擇。
        回傳選到的原始物件，取消則回傳 $null。
    #>
    param([object[]]$Items, [string]$Kind, [string]$Title)
    if (-not $Items -or $Items.Count -eq 0) { return $null }

    if (Test-GridViewAvailable) {
        try {
            $picked = Format-ForDisplay -Kind $Kind -InputObject $Items | Out-GridView -Title $Title -OutputMode Single
            if (-not $picked) { return $null }
            return $Items[[int]$picked.'#' - 1]
        }
        catch {
            Write-Host "無法開啟視窗（$($_.Exception.Message)），改用文字選單。" -ForegroundColor Yellow
            $script:Config.NoGui = $true
        }
    }

    Show-Table -Rows $Items -Kind $Kind -Title $Title
    while ($true) {
        $ans = Read-Host "請輸入編號 (1-$($Items.Count))，直接按 Enter 取消"
        if (-not $ans) { return $null }
        $n = 0
        if ([int]::TryParse($ans.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1] }
        Write-Host '編號不正確，請重新輸入。' -ForegroundColor Yellow
    }
}

function Show-Result {
    <# 顯示結果：有視窗就同時開 Out-GridView（唯讀檢視），主控台也印出 #>
    param([object[]]$Rows, [string]$Kind, [string]$Title)
    Show-Table -Rows $Rows -Kind $Kind -Title $Title
    if ((Test-GridViewAvailable) -and $Rows -and $Rows.Count -gt 0) {
        try { Format-ForDisplay -Kind $Kind -InputObject $Rows | Out-GridView -Title $Title }
        catch { $script:Config.NoGui = $true }
    }
}

function Read-ExportChoice {
    param([object[]]$Rows, [string]$Kind, [string]$Title, [string]$Subtitle)
    $fmt = Read-Host '匯出格式：[1] CSV  [2] HTML  [3] 兩種都要（預設 3）'
    $format = switch ($fmt) { '1' { 'CSV' } '2' { 'HTML' } default { 'Both' } }
    $def = Get-DefaultExportFolder
    $folder = Read-Host "存放資料夾（直接 Enter 使用 $def）"
    if (-not $folder) { $folder = $def }
    try {
        $files = Export-QueryReport -Kind $Kind -InputObject $Rows -Title $Title -Subtitle $Subtitle -Format $format -Folder $folder
        foreach ($f in $files) { Write-Host "已匯出：$f" -ForegroundColor Green }
    }
    catch {
        Write-Host "匯出失敗：$($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-MemberMenu {
    param($Permission)
    $recurseAns = Read-Host "是否展開巢狀群組（包含子群組內的成員）？[Y/n]"
    $recurse = -not ($recurseAns -match '^(n|no|否)$')
    $groupId = if ($Permission.DistinguishedName) { $Permission.DistinguishedName } else { $Permission.SamAccountName }
    Write-Host "查詢群組「$($Permission.Identity)」成員中..." -ForegroundColor Gray
    try {
        $all = @(Get-GroupMemberDetail -Identity $groupId -Recurse:$recurse)
    }
    catch {
        Write-Host "查詢群組成員失敗：$($_.Exception.Message)" -ForegroundColor Red
        return
    }
    $current = $all
    $filterText = ''
    $title = "群組成員：$($Permission.Identity)"
    Show-Result -Rows $current -Kind Member -Title $title
    while ($true) {
        $users = @($all | Where-Object { $_.ObjectClass -eq '使用者' })
        $abnormal = @($users | Where-Object { $_.Status -ne '正常' })
        Write-Host ''
        Write-Host ("共 {0} 筆（使用者 {1} 位，其中狀態異常 {2} 位）{3}" -f $all.Count, $users.Count, $abnormal.Count, $(if ($filterText) { "　目前篩選：$filterText → $($current.Count) 筆" } else { '' })) -ForegroundColor Cyan
        Write-Host '[F] 關鍵字篩選  [A] 只看狀態異常帳號  [C] 清除篩選  [E] 匯出目前清單  [S] 重新顯示  [B] 返回'
        $c = "$(Read-Host '請選擇')".Trim().ToUpperInvariant()
        switch ($c) {
            'F' {
                $kw = Read-Host '請輸入關鍵字（姓名、帳號、部門…，多個關鍵字用空白分隔）'
                $current = @(Select-ByKeyword -InputObject $all -Keyword $kw)
                $filterText = $kw
                Show-Table -Rows $current -Kind Member -Title "$title（篩選：$kw）"
            }
            'A' {
                $current = @($abnormal)
                $filterText = '狀態異常'
                Show-Table -Rows $current -Kind Member -Title "$title（狀態異常）"
            }
            'C' { $current = $all; $filterText = ''; Show-Table -Rows $current -Kind Member -Title $title }
            'E' { Read-ExportChoice -Rows $current -Kind Member -Title $title -Subtitle $(if ($filterText) { "篩選：$filterText" } else { '' }) }
            'S' { Show-Result -Rows $current -Kind Member -Title $title }
            'B' { return }
            default { Write-Host '請輸入選單上的代號。' -ForegroundColor Yellow }
        }
    }
}

function Invoke-PathMenu {
    param([string]$Path)
    Write-Host "讀取「$Path」的權限中..." -ForegroundColor Gray
    try {
        $result = Get-PathPermission -Path $Path
    }
    catch {
        Write-Host "讀取權限失敗：$($_.Exception.Message)" -ForegroundColor Red
        return
    }
    $perms = @($result.Permissions)
    $title = "權限清單：$Path"
    $sub = "擁有者：$($result.Owner)　繼承：$(if ($result.AreAccessRulesProtected) { '已中斷（不繼承上層）' } else { '有繼承上層' })"

    $showSummary = {
        Write-Host ''
        Write-Host $sub -ForegroundColor Cyan
        Show-Result -Rows $perms -Kind Permission -Title $title
        $orphans = @($perms | Where-Object { $_.Category -eq '孤立 SID' })
        if ($orphans.Count -gt 0) { Write-Host "注意：有 $($orphans.Count) 筆孤立 SID（帳戶可能已刪除）。" -ForegroundColor Yellow }
        $denies = @($perms | Where-Object { $_.AccessType -eq '拒絕' })
        if ($denies.Count -gt 0) { Write-Host "注意：有 $($denies.Count) 筆「拒絕」權限，拒絕會優先於允許。" -ForegroundColor Yellow }
    }
    & $showSummary

    while ($true) {
        Write-Host ''
        Write-Host '[1] 選擇群組查看成員  [2] 反查使用者權限  [3] 掃描子資料夾  [4] 匯出權限清單  [5] 重新顯示  [N] 查詢其他路徑  [Q] 離開'
        $c = "$(Read-Host '請選擇')".Trim().ToUpperInvariant()
        switch ($c) {
            '1' {
                $groups = @($perms | Where-Object { $_.CanExpand })
                if ($groups.Count -eq 0) { Write-Host '這個路徑上沒有可展開的 AD 群組。' -ForegroundColor Yellow; break }
                $g = Select-OneItem -Items $groups -Kind Permission -Title '請選擇要查詢的群組'
                if ($g) { Invoke-MemberMenu -Permission $g }
            }
            '2' {
                $user = Read-Host '請輸入使用者帳號（例如 jdoe 或 CORP\jdoe）'
                if (-not $user) { break }
                try {
                    $rows = @(Find-UserPathAccess -Path $Path -User $user -PermissionResult $result)
                    if ($rows.Count -eq 0) {
                        Write-Host "在此路徑上找不到 $user 可取得權限的項目（依 AD 群組判斷）。" -ForegroundColor Yellow
                    }
                    else {
                        Show-Result -Rows $rows -Kind Access -Title "使用者 $user 在 $Path 的權限來源"
                        if (@($rows | Where-Object { $_.AccessType -eq '拒絕' -and $_.Certainty -eq '確定' }).Count -gt 0) {
                            Write-Host '注意：此使用者有符合的「拒絕」權限，實際可能無法存取。' -ForegroundColor Yellow
                        }
                        $ex = Read-Host '要匯出這份結果嗎？[y/N]'
                        if ($ex -match '^(y|yes|是)$') { Read-ExportChoice -Rows $rows -Kind Access -Title "使用者權限反查_$user" -Subtitle $Path }
                    }
                }
                catch { Write-Host "反查失敗：$($_.Exception.Message)" -ForegroundColor Red }
            }
            '3' {
                $d = Read-Host '要往下掃描幾層？（1-20，預設 3；層數越多越久）'
                $depth = 3
                $tmp = 0
                if ([int]::TryParse("$d", [ref]$tmp) -and $tmp -ge 1 -and $tmp -le 20) { $depth = $tmp }
                $rows = @(Get-SubfolderPermissionDiff -Path $Path -Depth $depth)
                if ($rows.Count -eq 0) { Write-Host '所有子資料夾都是單純繼承上層權限，沒有差異。' -ForegroundColor Green }
                else {
                    Show-Result -Rows $rows -Kind Scan -Title "子資料夾權限差異：$Path"
                    $ex = Read-Host '要匯出這份結果嗎？[y/N]'
                    if ($ex -match '^(y|yes|是)$') { Read-ExportChoice -Rows $rows -Kind Scan -Title '子資料夾權限差異' -Subtitle $Path }
                }
            }
            '4' { Read-ExportChoice -Rows $perms -Kind Permission -Title '權限清單' -Subtitle "$Path　$sub" }
            '5' { & $showSummary }
            'N' { return 'next' }
            'Q' { return 'quit' }
            default { Write-Host '請輸入選單上的代號。' -ForegroundColor Yellow }
        }
    }
}

function Start-ADPermissionQuery {
    <#
    .SYNOPSIS
        互動式啟動：輸入路徑 → 列出權限 → 選群組 → 列出成員。全程唯讀。
    #>
    [CmdletBinding()]
    param([string]$Path)

    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ' 資料夾權限查詢工具（唯讀，不會修改 AD）' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan

    if (-not (Get-Command -Name Get-ADUser -ErrorAction SilentlyContinue)) {
        Write-Host '找不到 ActiveDirectory 模組。請先安裝 RSAT「Active Directory 網域服務工具」。' -ForegroundColor Red
        Write-Host '  Windows 10/11：設定 > 應用程式 > 選用功能 > 新增「RSAT: Active Directory Domain Services...」'
        Write-Host '  Windows Server：Install-WindowsFeature RSAT-AD-PowerShell（需由系統管理員安裝）'
        return
    }

    while ($true) {
        if (-not $Path) {
            $Path = Read-Host "`n請輸入資料夾路徑（例如 \\fileserver\share\財務部），輸入 Q 離開"
            if ($null -eq $Path) { return }
            $Path = $Path.Trim().Trim('"')
            if (-not $Path) { continue }
            if ($Path -match '^(q|quit|exit)$') { return }
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Host "找不到路徑或沒有讀取權限：$Path" -ForegroundColor Red
            $Path = $null
            continue
        }
        $r = Invoke-PathMenu -Path $Path
        $Path = $null
        if ($r -eq 'quit') { return }
    }
}

Export-ModuleMember -Function Start-ADPermissionQuery, Set-ADPermissionQueryOption, Get-PathPermission, Get-GroupMemberDetail,
Find-UserPathAccess, Get-SubfolderPermissionDiff, Export-QueryReport, Select-ByKeyword, Format-ForDisplay,
Convert-FileSystemRight, Convert-InheritanceToText, Resolve-AclIdentity, Get-PathAclInfo
