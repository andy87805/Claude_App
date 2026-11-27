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

$script:UserProperties = @('DisplayName', 'Department', 'Title', 'mail', 'telephoneNumber', 'mobile', 'Office', 'Company', 'Description',
    'EmployeeID', 'UserPrincipalName', 'Manager', 'Enabled', 'LockedOut', 'PasswordExpired', 'PasswordNeverExpires', 'PasswordLastSet',
    'LastLogonDate', 'AccountExpirationDate', 'whenCreated', 'MemberOf', 'PrimaryGroup')

function Get-ADUserDetail {
    <# 取得使用者詳細資料（Get-ADUser，唯讀） #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Identity)
    if ($script:UserCache.ContainsKey($Identity)) { return $script:UserCache[$Identity] }
    $srv = Get-ADServerParam
    $u = Get-ADUser -Identity $Identity -Properties $script:UserProperties @srv -ErrorAction Stop
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
                    $row = ConvertTo-UserRow -User $u -Via $via
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

    $sam = Get-SamFromInput $User

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
# 搜尋 AD 物件、使用者 / 電腦資訊、所屬群組、比較、群組用在哪些資料夾（全部唯讀）
# ---------------------------------------------------------------------------
$script:MaxSearchResults = 200
$script:ComputerProperties = @('DNSHostName', 'OperatingSystem', 'OperatingSystemVersion', 'IPv4Address', 'LastLogonDate',
    'Enabled', 'Description', 'whenCreated', 'PasswordLastSet', 'ManagedBy', 'Location', 'MemberOf', 'PrimaryGroup')

function Get-SamFromInput {
    <# 把使用者輸入的 CORP\jdoe、jdoe@corp.local 轉成 jdoe；DN 原樣保留 #>
    param([string]$Text)
    $t = "$Text".Trim().Trim('"')
    if ($t -match '^(CN|OU)=') { return $t }
    if ($t.Contains('\')) { $t = $t.Substring($t.IndexOf('\') + 1) }
    if ($t.Contains('@')) { $t = $t.Substring(0, $t.IndexOf('@')) }
    return $t
}

function Get-NameFromDN {
    param([string]$DistinguishedName)
    if ($DistinguishedName -match '^(?:CN|OU)=((?:\\,|[^,])+)') { return ($Matches[1] -replace '\\,', ',') }
    return [string]$DistinguishedName
}

function Get-OUFromDN {
    param([string]$DistinguishedName)
    if (-not $DistinguishedName) { return '' }
    return ($DistinguishedName -replace '^(?:CN|OU)=(?:\\,|[^,])+,', '')
}

function Format-InfoValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { if ($Value) { return '是' } else { return '否' } }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm') }
    return [string]$Value
}

function ConvertTo-GroupRow {
    param($Group, [string]$Via = '')
    $cat = switch ([string]$Group.GroupCategory) { 'Security' { '安全性' } 'Distribution' { '發佈' } default { [string]$Group.GroupCategory } }
    $scope = switch ([string]$Group.GroupScope) { 'Global' { '全域' } 'DomainLocal' { '網域本機' } 'Universal' { '萬用' } default { [string]$Group.GroupScope } }
    [pscustomobject]@{
        Name              = [string]$Group.Name
        SamAccountName    = [string]$Group.SamAccountName
        Category          = $cat
        Scope             = $scope
        Via               = $Via
        Description       = [string]$Group.Description
        DistinguishedName = [string]$Group.DistinguishedName
    }
}

function ConvertTo-UserRow {
    param($User, [string]$Via = '')
    [pscustomobject]@{
        Name                 = if ($User.DisplayName) { [string]$User.DisplayName } else { [string]$User.Name }
        SamAccountName       = [string]$User.SamAccountName
        ObjectClass          = '使用者'
        Department           = [string]$User.Department
        Title                = [string]$User.Title
        Email                = [string]$User.mail
        Phone                = [string]$User.telephoneNumber
        Office               = [string]$User.Office
        Enabled              = $User.Enabled
        Status               = Get-UserStatusText -User $User -InactiveDays $script:Config.InactiveDays
        LastLogonDate        = $User.LastLogonDate
        PasswordLastSet      = $User.PasswordLastSet
        PasswordNeverExpires = $User.PasswordNeverExpires
        Via                  = $Via
        DistinguishedName    = [string]$User.DistinguishedName
    }
}

function Get-ComputerStatusText {
    param($Computer)
    if ($Computer.Enabled -eq $false) { return '停用' }
    if (-not $Computer.LastLogonDate) { return '從未登入' }
    $days = ((Get-Date) - [datetime]$Computer.LastLogonDate).Days
    if ($days -gt $script:Config.InactiveDays) { return "超過 $($script:Config.InactiveDays) 天未登入" }
    return '正常'
}

function ConvertTo-ComputerRow {
    param($Computer)
    [pscustomobject]@{
        Name              = [string]$Computer.Name
        OperatingSystem   = [string]$Computer.OperatingSystem
        Status            = Get-ComputerStatusText -Computer $Computer
        LastLogonDate     = $Computer.LastLogonDate
        IPv4Address       = [string]$Computer.IPv4Address
        Description       = [string]$Computer.Description
        OU                = Get-OUFromDN ([string]$Computer.DistinguishedName)
        DistinguishedName = [string]$Computer.DistinguishedName
    }
}

function Find-ADGroupByName {
    <# 用名稱（可只輸入一部分）搜尋群組（唯讀） #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $n = ConvertTo-LdapFilterValue (Get-SamFromInput $Name)
    $srv = Get-ADServerParam
    $found = @(Get-ADGroup -Filter "Name -like '*$n*' -or SamAccountName -like '*$n*'" -Properties Description, GroupCategory, GroupScope -ResultSetSize $script:MaxSearchResults @srv -ErrorAction Stop)
    Write-QueryLog -Action '搜尋群組' -Target $Name
    @($found | ForEach-Object { ConvertTo-GroupRow -Group $_ } | Sort-Object Name)
}

function Find-ADUserByKeyword {
    <# 用帳號、姓名、Email、部門、職稱、員工編號搜尋使用者（唯讀） #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Keyword)
    $k = ConvertTo-LdapFilterValue (Get-SamFromInput $Keyword)
    $filter = "SamAccountName -like '*$k*' -or Name -like '*$k*' -or DisplayName -like '*$k*' -or mail -like '*$k*' -or Department -like '*$k*' -or Title -like '*$k*' -or EmployeeID -eq '$k'"
    $srv = Get-ADServerParam
    $found = @(Get-ADUser -Filter $filter -Properties $script:UserProperties -ResultSetSize $script:MaxSearchResults @srv -ErrorAction Stop)
    Write-QueryLog -Action '搜尋帳號' -Target $Keyword
    @($found | ForEach-Object { ConvertTo-UserRow -User $_ } | Sort-Object SamAccountName)
}

function Find-ADComputerByName {
    <# 用電腦名稱、DNS 名稱、描述搜尋電腦帳號（唯讀） #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $n = ConvertTo-LdapFilterValue ("$Name".Trim().TrimEnd('$'))
    $srv = Get-ADServerParam
    $found = @(Get-ADComputer -Filter "Name -like '*$n*' -or DNSHostName -like '*$n*' -or Description -like '*$n*'" -Properties $script:ComputerProperties -ResultSetSize $script:MaxSearchResults @srv -ErrorAction Stop)
    Write-QueryLog -Action '搜尋電腦' -Target $Name
    @($found | ForEach-Object { ConvertTo-ComputerRow -Computer $_ } | Sort-Object Name)
}

function Get-PrincipalGroupDetail {
    <#
    .SYNOPSIS
        列出使用者 / 電腦所屬的所有群組（含巢狀與主要群組），並標示取得方式（唯讀）。
        傳入的物件需含 MemberOf 與 PrimaryGroup 屬性。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Principal)
    $srv = Get-ADServerParam
    $rows = New-Object System.Collections.Generic.List[object]
    $visited = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($dn in @($Principal.MemberOf)) {
        if ($dn -and $visited.Add([string]$dn)) { $queue.Enqueue(@{ Dn = [string]$dn; Chain = @(); Primary = $false }) }
    }
    if ($Principal.PrimaryGroup -and $visited.Add([string]$Principal.PrimaryGroup)) {
        $queue.Enqueue(@{ Dn = [string]$Principal.PrimaryGroup; Chain = @(); Primary = $true })
    }
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        try {
            $g = Get-ADGroup -Identity $item.Dn -Properties MemberOf, Description, GroupCategory, GroupScope @srv -ErrorAction Stop
        }
        catch {
            Write-Warning "讀取群組 $($item.Dn) 失敗：$($_.Exception.Message)"
            continue
        }
        $via = if ($item.Chain.Count -gt 0) { '透過 ' + ($item.Chain -join ' > ') } elseif ($item.Primary) { '直接（主要群組）' } else { '直接' }
        $rows.Add((ConvertTo-GroupRow -Group $g -Via $via))
        foreach ($p in @($g.MemberOf)) {
            if ($p -and $visited.Add([string]$p)) { $queue.Enqueue(@{ Dn = [string]$p; Chain = @($item.Chain + [string]$g.Name); Primary = $false }) }
        }
    }
    return $rows.ToArray()
}

function Get-ADUserInfo {
    <# 使用者詳細資料與所屬群組（唯讀） #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Identity)
    $u = Get-ADUserDetail -Identity (Get-SamFromInput $Identity)
    $groups = @(Get-PrincipalGroupDetail -Principal $u)
    $expires = if ($u.AccountExpirationDate) { Format-InfoValue $u.AccountExpirationDate } else { '永不到期' }
    $pairs = [ordered]@{
        '姓名'         = Format-InfoValue $u.DisplayName
        '帳號'         = Format-InfoValue $u.SamAccountName
        'UPN'          = Format-InfoValue $u.UserPrincipalName
        '員工編號'     = Format-InfoValue $u.EmployeeID
        '部門'         = Format-InfoValue $u.Department
        '職稱'         = Format-InfoValue $u.Title
        '公司'         = Format-InfoValue $u.Company
        '辦公室'       = Format-InfoValue $u.Office
        'Email'        = Format-InfoValue $u.mail
        '電話'         = Format-InfoValue $u.telephoneNumber
        '手機'         = Format-InfoValue $u.mobile
        '主管'         = if ($u.Manager) { Get-NameFromDN ([string]$u.Manager) } else { '' }
        '帳號狀態'     = Get-UserStatusText -User $u -InactiveDays $script:Config.InactiveDays
        '啟用'         = Format-InfoValue $u.Enabled
        '鎖定'         = Format-InfoValue $u.LockedOut
        '密碼已過期'   = Format-InfoValue $u.PasswordExpired
        '密碼永不過期' = Format-InfoValue $u.PasswordNeverExpires
        '密碼設定日'   = Format-InfoValue $u.PasswordLastSet
        '最後登入'     = Format-InfoValue $u.LastLogonDate
        '帳號到期日'   = $expires
        '建立日期'     = Format-InfoValue $u.whenCreated
        '描述'         = Format-InfoValue $u.Description
        '所在 OU'      = Get-OUFromDN ([string]$u.DistinguishedName)
        '所屬群組數'   = "$($groups.Count)（直接 $(@($groups | Where-Object { $_.Via -like '直接*' }).Count)）"
    }
    Write-QueryLog -Action '查詢使用者資訊' -Target ([string]$u.SamAccountName)
    [pscustomobject]@{
        User   = ConvertTo-UserRow -User $u
        Info   = @(foreach ($k in $pairs.Keys) { [pscustomobject]@{ Field = $k; Value = $pairs[$k] } })
        Groups = $groups
    }
}

function Get-ADComputerInfo {
    <# 電腦帳號詳細資料與所屬群組（唯讀） #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Identity)
    $srv = Get-ADServerParam
    $c = Get-ADComputer -Identity ("$Identity".Trim()) -Properties $script:ComputerProperties @srv -ErrorAction Stop
    $groups = @(Get-PrincipalGroupDetail -Principal $c)
    $pairs = [ordered]@{
        '名稱'       = Format-InfoValue $c.Name
        'DNS 名稱'   = Format-InfoValue $c.DNSHostName
        '作業系統'   = Format-InfoValue $c.OperatingSystem
        '版本'       = Format-InfoValue $c.OperatingSystemVersion
        'IP 位址'    = Format-InfoValue $c.IPv4Address
        '狀態'       = Get-ComputerStatusText -Computer $c
        '最後登入'   = Format-InfoValue $c.LastLogonDate
        '密碼設定日' = Format-InfoValue $c.PasswordLastSet
        '建立日期'   = Format-InfoValue $c.whenCreated
        '描述'       = Format-InfoValue $c.Description
        '位置'       = Format-InfoValue $c.Location
        '管理者'     = if ($c.ManagedBy) { Get-NameFromDN ([string]$c.ManagedBy) } else { '' }
        '所在 OU'    = Get-OUFromDN ([string]$c.DistinguishedName)
        '所屬群組數' = "$($groups.Count)"
    }
    Write-QueryLog -Action '查詢電腦資訊' -Target ([string]$c.Name)
    [pscustomobject]@{
        Computer = ConvertTo-ComputerRow -Computer $c
        Info     = @(foreach ($k in $pairs.Keys) { [pscustomobject]@{ Field = $k; Value = $pairs[$k] } })
        Groups   = $groups
    }
}

function Compare-ADUserGroup {
    <# 比較兩位使用者所屬的群組（含巢狀），列出各自獨有與共同的群組（唯讀） #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserA,
        [Parameter(Mandatory)][string]$UserB
    )
    $a = Get-ADUserDetail -Identity (Get-SamFromInput $UserA)
    $b = Get-ADUserDetail -Identity (Get-SamFromInput $UserB)
    $nameA = [string]$a.SamAccountName
    $nameB = [string]$b.SamAccountName
    $mapA = @{}; foreach ($g in @(Get-PrincipalGroupDetail -Principal $a)) { $mapA[$g.DistinguishedName] = $g }
    $mapB = @{}; foreach ($g in @(Get-PrincipalGroupDetail -Principal $b)) { $mapB[$g.DistinguishedName] = $g }

    $keys = @(@($mapA.Keys) + @($mapB.Keys) | Sort-Object -Unique)
    $rows = foreach ($k in $keys) {
        $ga = $mapA[$k]; $gb = $mapB[$k]
        $g = if ($ga) { $ga } else { $gb }
        $result = if ($ga -and $gb) { '兩者都有' } elseif ($ga) { "只有 $nameA" } else { "只有 $nameB" }
        $order = if ($ga -and $gb) { 2 } elseif ($ga) { 0 } else { 1 }
        [pscustomobject]@{
            Name              = $g.Name
            Category          = $g.Category
            Scope             = $g.Scope
            Result            = $result
            ViaA              = if ($ga) { $ga.Via } else { '' }
            ViaB              = if ($gb) { $gb.Via } else { '' }
            Description       = $g.Description
            DistinguishedName = $k
            SortOrder         = $order
        }
    }
    Write-QueryLog -Action '比較使用者群組' -Target "$nameA vs $nameB"
    [pscustomobject]@{
        UserA = ConvertTo-UserRow -User $a
        UserB = ConvertTo-UserRow -User $b
        Rows  = @($rows | Sort-Object SortOrder, Name)
    }
}

function Find-GroupFolderUsage {
    <#
    .SYNOPSIS
        從指定路徑往下掃描，找出有給某個群組權限的資料夾（唯讀）。
        預設只列「明確設定」的權限（起始資料夾一律列出），-IncludeInherited 會連繼承來的一起列。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Group,
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(0, 20)][int]$Depth = 3,
        [switch]$IncludeInherited
    )
    $srv = Get-ADServerParam
    $g = Get-ADGroup -Identity $Group @srv -ErrorAction Stop
    $sid = [string]$g.SID
    $namePattern = '\\' + [regex]::Escape([string]$g.SamAccountName) + '$'

    $errs = $null
    $folders = @($Path)
    if ($Depth -gt 0) {
        $folders += @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Depth ($Depth - 1) -Force -ErrorAction SilentlyContinue -ErrorVariable errs | ForEach-Object { $_.FullName })
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($f in $folders) {
        $i++
        Write-Progress -Activity "搜尋群組 $($g.Name) 的權限" -Status $f -PercentComplete ([int](100 * $i / [math]::Max(1, $folders.Count)))
        try { $info = Get-PathAclInfo -Path $f }
        catch {
            $rows.Add([pscustomobject]@{ Folder = $f; Identity = ''; Rights = ''; AccessType = ''; AppliesTo = ''; IsInherited = $null; Note = "無法讀取：$($_.Exception.Message)" })
            continue
        }
        foreach ($r in $info.Rules) {
            $isMatch = ($sid -and $r.Sid -eq $sid) -or (-not $r.Sid -and $r.Identity -match $namePattern)
            if (-not $isMatch) { continue }
            if ($r.IsInherited -and -not $IncludeInherited -and $f -ne $Path) { continue }
            $rows.Add([pscustomobject]@{
                    Folder      = $f
                    Identity    = $r.Identity
                    Rights      = Convert-FileSystemRight -Rights $r.Rights
                    AccessType  = if ($r.AccessControlType -eq 'Deny') { '拒絕' } else { '允許' }
                    AppliesTo   = Convert-InheritanceToText -InheritanceFlags $r.InheritanceFlags -PropagationFlags $r.PropagationFlags
                    IsInherited = $r.IsInherited
                    Note        = ''
                })
        }
    }
    Write-Progress -Activity "搜尋群組 $($g.Name) 的權限" -Completed
    foreach ($e in @($errs)) {
        if (-not $e) { continue }
        $rows.Add([pscustomobject]@{ Folder = [string]$e.TargetObject; Identity = ''; Rights = ''; AccessType = ''; AppliesTo = ''; IsInherited = $null; Note = "無法列出：$($e.Exception.Message)" })
    }
    Write-QueryLog -Action "查詢群組使用處(深度 $Depth)" -Target "$($g.Name) @ $Path"
    return $rows.ToArray()
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
    Group      = [ordered]@{ Name = '群組名稱'; SamAccountName = '帳號'; Category = '類型'; Scope = '範圍'; Via = '取得方式'; Description = '描述' }
    User       = [ordered]@{ Name = '姓名'; SamAccountName = '帳號'; Department = '部門'; Title = '職稱'; Email = 'Email'; Phone = '電話'; Status = '帳號狀態'; LastLogonDate = '最後登入' }
    Computer   = [ordered]@{ Name = '電腦名稱'; OperatingSystem = '作業系統'; Status = '狀態'; LastLogonDate = '最後登入'; IPv4Address = 'IP 位址'; Description = '描述'; OU = '所在 OU' }
    Info       = [ordered]@{ Field = '項目'; Value = '內容' }
    Compare    = [ordered]@{ Name = '群組名稱'; Category = '類型'; Scope = '範圍'; Result = '比較結果'; ViaA = 'A 的取得方式'; ViaB = 'B 的取得方式'; Description = '描述' }
    Usage      = [ordered]@{ Folder = '資料夾'; Identity = '帳戶'; Rights = '權限'; AccessType = '允許/拒絕'; AppliesTo = '套用到'; IsInherited = '繼承'; Note = '備註' }
}

function Format-ForDisplay {
    <# 轉成中文欄位名稱的顯示物件，並加上 # 編號 #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Permission', 'Member', 'Access', 'Scan', 'Group', 'User', 'Computer', 'Info', 'Compare', 'Usage')][string]$Kind,
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
        [Parameter(Mandatory)][ValidateSet('Permission', 'Member', 'Access', 'Scan', 'Group', 'User', 'Computer', 'Info', 'Compare', 'Usage')][string]$Kind,
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

# ---------------------------------------------------------------------------
# 主控台排版
#   - 中日韓文字與全形符號在主控台佔 2 格，自行計算寬度讓表格對齊（Format-Table 在 5.1 會歪）
#   - 只用 ASCII 的線條（- =）：─、… 這類「寬度不明確」的字元在繁中主控台會佔 2 格而跑版
# ---------------------------------------------------------------------------
$script:WideCharPattern = New-Object System.Text.RegularExpressions.Regex('[ᄀ-ᅟ⺀-〾ぁ-㏿㐀-䶿一-鿿ꀀ-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]')

function Get-ConsoleWidth {
    $w = 0
    try { $w = [int]$Host.UI.RawUI.WindowSize.Width } catch { $w = 0 }
    if ($w -lt 60) { $w = 120 }
    return $w
}

function Get-ConsoleHeight {
    $h = 0
    try { $h = [int]$Host.UI.RawUI.WindowSize.Height } catch { $h = 0 }
    if ($h -lt 15) { $h = 40 }
    return $h
}

function Get-DisplayWidth {
    <# 主控台顯示寬度：中日韓文字與全形符號佔 2 格 #>
    param([string]$Text)
    if (-not $Text) { return 0 }
    return $Text.Length + $script:WideCharPattern.Matches($Text).Count
}

function Format-Cell {
    <# 把文字補空白或截斷到指定顯示寬度；-KeepTail 截斷時保留後段（適合路徑） #>
    param([string]$Text, [int]$Width, [switch]$KeepTail)
    $t = ("$Text" -replace '[\r\n\t]+', ' ')
    $w = Get-DisplayWidth $t
    if ($w -le $Width) { return $t + (' ' * ($Width - $w)) }
    if ($Width -le 2) { return ('.' * $Width) }
    $target = $Width - 2
    $sb = New-Object System.Text.StringBuilder
    $used = 0
    if ($KeepTail) {
        for ($i = $t.Length - 1; $i -ge 0; $i--) {
            $cw = Get-DisplayWidth ([string]$t[$i])
            if ($used + $cw -gt $target) { break }
            [void]$sb.Insert(0, $t[$i]); $used += $cw
        }
        return '..' + $sb.ToString() + (' ' * ($target - $used))
    }
    foreach ($ch in $t.ToCharArray()) {
        $cw = Get-DisplayWidth ([string]$ch)
        if ($used + $cw -gt $target) { break }
        [void]$sb.Append($ch); $used += $cw
    }
    return $sb.ToString() + '..' + (' ' * ($target - $used))
}

function Write-Status {
    <# 統一格式的訊息：Error [X] 紅、Warn [!] 黃、Ok [OK] 綠、Info 灰、Hint 暗灰 #>
    param([string]$Message, [ValidateSet('Info', 'Note', 'Ok', 'Warn', 'Error', 'Hint')][string]$Level = 'Info')
    switch ($Level) {
        'Note'  { Write-Host "  $Message" -ForegroundColor Cyan }
        'Error' { Write-Host "  [X] $Message" -ForegroundColor Red }
        'Warn'  { Write-Host "  [!] $Message" -ForegroundColor Yellow }
        'Ok'    { Write-Host "  [OK] $Message" -ForegroundColor Green }
        'Hint'  { Write-Host "  $Message" -ForegroundColor DarkGray }
        default { Write-Host "  $Message" -ForegroundColor Gray }
    }
}

function Write-Section {
    <# 區塊標題：標題文字＋等長的底線 #>
    param([string]$Title)
    $line = [Math]::Min([Math]::Max((Get-DisplayWidth $Title) + 2, 20), (Get-ConsoleWidth) - 2)
    Write-Host ''
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host (' ' + ('-' * $line)) -ForegroundColor DarkGray
}

function Show-Options {
    <# 選單選項自動排成多欄；項目格式 'K|說明'，代號以黃色顯示 #>
    param([string[]]$Items)
    $parsed = @(foreach ($it in $Items) { $k, $l = $it -split '\|', 2; [pscustomobject]@{ Key = $k; Label = $l } })
    $cellW = 0
    foreach ($p in $parsed) { $cellW = [Math]::Max($cellW, (Get-DisplayWidth "[$($p.Key)] $($p.Label)") + 3) }
    $perRow = [Math]::Max(1, [Math]::Min(4, [Math]::Floor(((Get-ConsoleWidth) - 4) / [Math]::Max(1, $cellW))))
    Write-Host ''
    for ($i = 0; $i -lt $parsed.Count; $i += $perRow) {
        Write-Host '  ' -NoNewline
        for ($j = $i; $j -lt [Math]::Min($i + $perRow, $parsed.Count); $j++) {
            $p = $parsed[$j]
            Write-Host "[$($p.Key)]" -NoNewline -ForegroundColor Yellow
            $label = " $($p.Label)"
            if ($j -lt [Math]::Min($i + $perRow, $parsed.Count) - 1) { $label = Format-Cell $label ($cellW - (Get-DisplayWidth "[$($p.Key)]")) }
            Write-Host $label -NoNewline
        }
        Write-Host ''
    }
}

function Get-CellColor {
    <# 依欄位與內容決定顏色：拒絕紅、異常黃 #>
    param([string]$Column, [string]$Value)
    if (-not $Value) { return $null }
    switch -Regex ($Column) {
        '^#$'                { return 'DarkGray' }
        '允許/拒絕'          { if ($Value -eq '拒絕') { return 'Red' }; return $null }
        '^(帳號狀態|狀態)$'  { if ($Value -ne '正常' -and $Value -notlike '（*') { return 'Yellow' }; return $null }
        '^類型$'             { if ($Value -eq '孤立 SID') { return 'Yellow' }; return $null }
        '^中斷繼承$'         { if ($Value -eq '是') { return 'Yellow' }; return $null }
        '^比較結果$'         { if ($Value -eq '兩者都有') { return 'DarkGray' }; return 'Yellow' }
        '^(備註|描述)$'      { return 'DarkGray' }
    }
    return $null
}

# 主控台表格的欄位設定：Hide = 主控台不顯示（視窗與匯出仍完整）、ShrinkFirst = 寬度不夠時優先縮減
$script:ConsoleView = @{
    Permission = @{ Hide = @(); ShrinkFirst = @('備註', '顯示名稱', '套用到') }
    Member     = @{ Hide = @('電話', '密碼設定日'); ShrinkFirst = @('Email', '取得途徑', '職稱') }
    Access     = @{ Hide = @(); ShrinkFirst = @('確定性', '對應項目', '套用到') }
    Scan       = @{ Hide = @(); ShrinkFirst = @('備註', '套用到', '帳戶') }
    Group      = @{ Hide = @(); ShrinkFirst = @('描述', '取得方式') }
    User       = @{ Hide = @('電話'); ShrinkFirst = @('Email', '職稱') }
    Computer   = @{ Hide = @(); ShrinkFirst = @('描述', '所在 OU', '作業系統') }
    Info       = @{ Hide = @(); ShrinkFirst = @() }
    Compare    = @{ Hide = @(); ShrinkFirst = @('描述', 'B 的取得方式', 'A 的取得方式') }
    Usage      = @{ Hide = @(); ShrinkFirst = @('備註', '套用到') }
}

function Show-Table {
    <#
        在主控台顯示表格：中文對齊、依視窗寬度自動縮欄、太長的內容截斷（完整內容請用視窗或匯出）、
        整欄空白的欄位不顯示、超過一頁時分頁。
    #>
    param([object[]]$Rows, [string]$Kind, [string]$Title)
    if ($Title) { Write-Section $Title }
    if (-not $Rows -or $Rows.Count -eq 0) { Write-Status '（沒有資料）' -Level Hint; return }

    $data = @(Format-ForDisplay -Kind $Kind -InputObject $Rows)
    $view = $script:ConsoleView[$Kind]
    $cols = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($data[0].PSObject.Properties | ForEach-Object Name)) {
        if ($view -and $view.Hide -contains $name) { continue }
        $hasValue = $false
        foreach ($d in $data) { if ("$($d.$name)" -ne '') { $hasValue = $true; break } }
        if ($hasValue) { $cols.Add($name) }
    }
    # 日期在主控台只顯示到日（視窗與匯出保留時間）
    foreach ($d in $data) {
        foreach ($c in $cols) {
            $v = "$($d.$c)"
            if ($v -match '^(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}$') { $d.$c = $Matches[1] }
        }
    }
    $cols = @($cols)
    $tailCols = @('資料夾')
    $natural = @{}
    foreach ($c in $cols) {
        $w = Get-DisplayWidth $c
        foreach ($d in $data) { $w = [Math]::Max($w, (Get-DisplayWidth "$($d.$c)")) }
        $natural[$c] = [Math]::Min($w, 60)
    }
    $indent = 2; $gap = 2
    $consoleWidth = Get-ConsoleWidth
    $shrinkFirst = @(); if ($view) { $shrinkFirst = @($view.ShrinkFirst) }
    # 縮到最小仍放不下時，依序暫時隱藏的欄位：先次要欄位，再從右邊開始（保留 # 與第一欄）
    $dropOrder = @($shrinkFirst | Where-Object { $cols -contains $_ })
    for ($k = $cols.Count - 1; $k -ge 2; $k--) { if ($dropOrder -notcontains $cols[$k]) { $dropOrder += $cols[$k] } }
    $hidden = @()
    while ($true) {
        $widths = @{}; foreach ($c in $cols) { $widths[$c] = $natural[$c] }
        $avail = $consoleWidth - 1 - $indent - $gap * ($cols.Count - 1)
        $total = 0; foreach ($c in $cols) { $total += $widths[$c] }
        # 1. 先縮次要欄位（最小 10）
        foreach ($c in $shrinkFirst) {
            if ($cols -notcontains $c -or $total -le $avail) { continue }
            $min = [Math]::Max(10, (Get-DisplayWidth $c))
            $new = [Math]::Max($min, $widths[$c] - ($total - $avail))
            if ($new -lt $widths[$c]) { $total -= ($widths[$c] - $new); $widths[$c] = $new }
        }
        # 2. 再從最寬的欄位開始縮（最小 8）
        while ($total -gt $avail) {
            $widest = $null
            foreach ($c in $cols) { if ($c -ne '#' -and (-not $widest -or $widths[$c] -gt $widths[$widest])) { $widest = $c } }
            if (-not $widest -or $widths[$widest] -le 8) { break }
            $widths[$widest]--; $total--
        }
        if ($total -le $avail) { break }
        # 3. 還是放不下：隱藏一個欄位後重算
        $drop = $null
        foreach ($c in $dropOrder) { if ($cols -contains $c) { $drop = $c; break } }
        if (-not $drop -or $cols.Count -le 3) { break }
        $cols = @($cols | Where-Object { $_ -ne $drop })
        $hidden += $drop
    }
    $pad = ' ' * $indent; $sep = ' ' * $gap
    Write-Host ($pad + ((@($cols) | ForEach-Object { Format-Cell $_ $widths[$_] }) -join $sep).TrimEnd()) -ForegroundColor Cyan
    Write-Host ($pad + ((@($cols) | ForEach-Object { '-' * $widths[$_] }) -join $sep)) -ForegroundColor DarkGray

    if ($hidden.Count -gt 0) {
        Write-Status "視窗太窄，未顯示：$($hidden -join '、')（可放大視窗，或用 [S] 開視窗、[E] 匯出查看完整內容）" -Level Hint
    }
    $pageSize = [Math]::Max(15, (Get-ConsoleHeight) - 8)
    for ($i = 0; $i -lt $data.Count; $i++) {
        if ($i -gt 0 -and ($i % $pageSize) -eq 0) {
            $more = Read-Host "  -- 已顯示 $i / $($data.Count) 筆，按 Enter 繼續，輸入 Q 停止 --"
            if ("$more".Trim() -match '^(q|quit)$') {
                Write-Status "其餘 $($data.Count - $i) 筆未顯示，可用 [S] 開視窗或 [E] 匯出查看完整清單。" -Level Hint
                break
            }
        }
        $d = $data[$i]
        $cells = foreach ($c in $cols) {
            $raw = "$($d.$c)"
            [pscustomobject]@{ Text = (Format-Cell $raw $widths[$c] -KeepTail:($tailCols -contains $c)); Color = (Get-CellColor -Column $c -Value $raw) }
        }
        if (-not @($cells | Where-Object { $_.Color })) {
            Write-Host ($pad + ((@($cells) | ForEach-Object Text) -join $sep).TrimEnd())
            continue
        }
        Write-Host $pad -NoNewline
        $n = 0
        foreach ($cell in $cells) {
            $n++
            $text = if ($n -eq @($cells).Count) { $cell.Text.TrimEnd() } else { $cell.Text + $sep }
            if ($cell.Color) {
                Write-Host $cell.Text.TrimEnd() -NoNewline -ForegroundColor $cell.Color
                $rest = $text.Substring($cell.Text.TrimEnd().Length)
                if ($rest) { Write-Host $rest -NoNewline }
            }
            else { Write-Host $text -NoNewline }
        }
        Write-Host ''
    }
}

function Show-InfoBlock {
    <# 「項目 : 內容」對齊顯示 #>
    param([object[]]$Info, [string]$Title)
    Write-Section $Title
    $Info = @($Info | Where-Object { "$($_.Value)" -ne '' })   # 空白的項目不顯示（匯出時仍保留）
    $w = 0
    foreach ($i in $Info) { $w = [Math]::Max($w, (Get-DisplayWidth ([string]$i.Field))) }
    foreach ($i in $Info) {
        Write-Host ('  ' + (Format-Cell ([string]$i.Field) $w) + ' : ') -NoNewline -ForegroundColor Gray
        if ($i.Field -match '狀態' -and $i.Value -and $i.Value -ne '正常') { Write-Host $i.Value -ForegroundColor Yellow }
        else { Write-Host $i.Value }
    }
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
            Write-Status "無法開啟視窗（$($_.Exception.Message)），改用文字選單。" -Level Warn
            $script:Config.NoGui = $true
        }
    }

    Show-Table -Rows $Items -Kind $Kind -Title $Title
    while ($true) {
        $ans = Read-Host "  請輸入編號 (1-$($Items.Count))，直接按 Enter 取消"
        if (-not $ans) { return $null }
        $n = 0
        if ([int]::TryParse($ans.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1] }
        Write-Status '編號不正確，請重新輸入。' -Level Warn
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
    $fmt = Read-Host '  匯出格式：[1] CSV  [2] HTML  [3] 兩種都要（預設 3）'
    $format = switch ($fmt) { '1' { 'CSV' } '2' { 'HTML' } default { 'Both' } }
    $def = Get-DefaultExportFolder
    $folder = Read-Host "  存放資料夾（直接 Enter 使用 $def）"
    if (-not $folder) { $folder = $def }
    try {
        $files = Export-QueryReport -Kind $Kind -InputObject $Rows -Title $Title -Subtitle $Subtitle -Format $format -Folder $folder
        foreach ($f in $files) { Write-Status "已匯出：$f" -Level Ok }
    }
    catch {
        Write-Status "匯出失敗：$($_.Exception.Message)" -Level Error
    }
}

function Read-Choice {
    param([string]$Prompt)
    return "$(Read-Host "  $Prompt")".Trim()
}

function Read-YesNo {
    <# 是否題：預設值由 -Default 決定 #>
    param([string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Choice "$Prompt$hint"
    if (-not $a) { return $Default }
    return ($a -match '^(y|yes|是)$')
}

function Read-PathInput {
    <# 讀取並檢查路徑；直接按 Enter 或輸入 Q 回到上一層（回傳 $null） #>
    param([string]$Prompt = '請輸入資料夾路徑（例如 \\fileserver\share\財務部），直接按 Enter 返回')
    while ($true) {
        $p = (Read-Choice $Prompt).Trim('"')
        if (-not $p -or $p -match '^(q|quit|exit|b)$') { return $null }
        if (Test-Path -LiteralPath $p) { return $p }
        Write-Status "找不到路徑或沒有讀取權限：$p" -Level Error
    }
}

function Read-DepthInput {
    param([int]$Default = 3, [int]$Min = 1)
    $d = Read-Choice "要往下掃描幾層子資料夾？（$Min-20，預設 $Default；層數越多越久）"
    $n = 0
    if ([int]::TryParse($d, [ref]$n) -and $n -ge $Min -and $n -le 20) { return $n }
    return $Default
}

function Select-GroupInteractive {
    <# 輸入群組名稱（可只輸入一部分）→ 找到多筆時讓使用者挑選。回傳群組列或 $null #>
    param([string]$Prompt = '請輸入群組名稱（可只輸入一部分），直接按 Enter 返回')
    $name = Read-Choice $Prompt
    if (-not $name) { return $null }
    try { $found = @(Find-ADGroupByName -Name $name) }
    catch { Write-Status "搜尋群組失敗：$($_.Exception.Message)" -Level Error; return $null }
    if ($found.Count -eq 0) { Write-Status "找不到名稱包含「$name」的群組。" -Level Warn; return $null }
    $key = Get-SamFromInput $name
    $exact = @($found | Where-Object { $_.SamAccountName -eq $key -or $_.Name -eq $key })
    if ($exact.Count -eq 1) { return $exact[0] }
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -ge $script:MaxSearchResults) { Write-Status "符合的群組太多，只列出前 $($script:MaxSearchResults) 筆，可輸入更完整的名稱。" -Level Warn }
    return (Select-OneItem -Items $found -Kind Group -Title "找到 $($found.Count) 個群組，請選擇")
}

function Select-UserInteractive {
    <# 輸入帳號或姓名等關鍵字 → 帳號完全符合就直接使用，否則搜尋並讓使用者挑選。回傳 DN 或 $null #>
    param([string]$Prompt = '請輸入使用者帳號或姓名（例如 jdoe、CORP\jdoe、王小明），直接按 Enter 返回')
    $text = Read-Choice $Prompt
    if (-not $text) { return $null }
    try { return [string](Get-ADUserDetail -Identity (Get-SamFromInput $text)).DistinguishedName } catch { Write-Verbose "不是完整帳號，改用關鍵字搜尋：$text" }
    try { $found = @(Find-ADUserByKeyword -Keyword $text) }
    catch { Write-Status "搜尋帳號失敗：$($_.Exception.Message)" -Level Error; return $null }
    if ($found.Count -eq 0) { Write-Status "找不到符合「$text」的使用者。" -Level Warn; return $null }
    if ($found.Count -eq 1) { return $found[0].DistinguishedName }
    if ($found.Count -ge $script:MaxSearchResults) { Write-Status "符合的帳號太多，只列出前 $($script:MaxSearchResults) 筆，可輸入更完整的關鍵字。" -Level Warn }
    $u = Select-OneItem -Items $found -Kind User -Title "找到 $($found.Count) 位使用者，請選擇"
    if ($u) { return $u.DistinguishedName }
    return $null
}

function Select-ComputerInteractive {
    <# 輸入電腦名稱（可只輸入一部分）→ 回傳電腦 DN 或 $null #>
    param([string]$Prompt = '請輸入電腦名稱（可只輸入一部分），直接按 Enter 返回')
    $text = Read-Choice $Prompt
    if (-not $text) { return $null }
    try { $found = @(Find-ADComputerByName -Name $text) }
    catch { Write-Status "搜尋電腦失敗：$($_.Exception.Message)" -Level Error; return $null }
    if ($found.Count -eq 0) { Write-Status "找不到名稱包含「$text」的電腦。" -Level Warn; return $null }
    $exact = @($found | Where-Object { $_.Name -eq $text.Trim().TrimEnd('$') })
    if ($exact.Count -eq 1) { return $exact[0].DistinguishedName }
    if ($found.Count -eq 1) { return $found[0].DistinguishedName }
    if ($found.Count -ge $script:MaxSearchResults) { Write-Status "符合的電腦太多，只列出前 $($script:MaxSearchResults) 筆。" -Level Warn }
    $c = Select-OneItem -Items $found -Kind Computer -Title "找到 $($found.Count) 台電腦，請選擇"
    if ($c) { return $c.DistinguishedName }
    return $null
}

function Invoke-ListMenu {
    <#
        通用的清單操作：篩選、清除篩選、匯出、重新顯示、返回。
        -Extra 可加入額外選項，例如 @{ Key = 'M'; Label = '查看群組成員'; Action = { param($current) ... } }
    #>
    param(
        [object[]]$Rows, [string]$Kind, [string]$Title, [string]$ExportTitle, [string]$Subtitle = '',
        [object[]]$Extra = @(), [scriptblock]$Summary
    )
    $all = @($Rows)
    $current = $all
    $filterText = ''
    while ($true) {
        Write-Host ''
        $line = "共 $($all.Count) 筆"
        if ($filterText) { $line += "　目前篩選：$filterText → $($current.Count) 筆" }
        Write-Status $line -Level Note
        if ($Summary) { & $Summary $all }
        $opts = @()
        foreach ($x in $Extra) { $opts += "$($x.Key)|$($x.Label)" }
        $opts += 'F|關鍵字篩選', 'C|清除篩選', 'E|匯出目前清單', 'S|重新顯示（開視窗）', 'B|返回'
        Show-Options $opts
        $c = (Read-Choice '請選擇').ToUpperInvariant()
        $handled = $false
        foreach ($x in $Extra) {
            if ($c -eq $x.Key) {
                $r = & $x.Action $current $all
                if ($null -ne $r) { $current = @($r); $filterText = $x.Label; Show-Table -Rows $current -Kind $Kind -Title "$Title（$($x.Label)）" }
                $handled = $true
            }
        }
        if ($handled) { continue }
        switch ($c) {
            'F' {
                $kw = Read-Choice '請輸入關鍵字（多個關鍵字用空白分隔）'
                $current = @(Select-ByKeyword -InputObject $all -Keyword $kw)
                $filterText = $kw
                Show-Table -Rows $current -Kind $Kind -Title "$Title（篩選：$kw）"
            }
            'C' { $current = $all; $filterText = ''; Show-Table -Rows $current -Kind $Kind -Title $Title }
            'E' {
                $sub = $Subtitle
                if ($filterText) { $sub = ("$sub　篩選：$filterText").Trim('　') }
                Read-ExportChoice -Rows $current -Kind $Kind -Title $ExportTitle -Subtitle $sub
            }
            'S' { Show-Result -Rows $current -Kind $Kind -Title $Title }
            'B' { return }
            default { Write-Status '請輸入選單上的代號。' -Level Warn }
        }
    }
}

function Invoke-MemberMenu {
    <# 列出群組成員並提供篩選 / 只看異常 / 匯出 #>
    param([Parameter(Mandatory)][string]$GroupId, [string]$Label)
    if (-not $Label) { $Label = Get-NameFromDN $GroupId }
    $recurse = Read-YesNo -Prompt '是否展開巢狀群組（包含子群組內的成員）？' -Default $true
    Write-Status "查詢群組「$Label」成員中..." -Level Info
    try {
        $all = @(Get-GroupMemberDetail -Identity $GroupId -Recurse:$recurse)
    }
    catch {
        Write-Status "查詢群組成員失敗：$($_.Exception.Message)" -Level Error
        return
    }
    $title = "群組成員：$Label"
    Show-Result -Rows $all -Kind Member -Title $title
    $summary = {
        param($rows)
        $users = @($rows | Where-Object { $_.ObjectClass -eq '使用者' })
        $abnormal = @($users | Where-Object { $_.Status -ne '正常' })
        Write-Status "使用者 $($users.Count) 位，其中狀態異常 $($abnormal.Count) 位" -Level Note
    }
    $extra = @(
        @{ Key = 'A'; Label = '只看狀態異常帳號'; Action = { param($cur, $full) @($full | Where-Object { $_.ObjectClass -eq '使用者' -and $_.Status -ne '正常' }) } }
        @{ Key = 'V'; Label = '查看某位成員的詳細資料'; Action = {
                param($cur)
                $users = @($cur | Where-Object { $_.ObjectClass -eq '使用者' })
                $u = Select-OneItem -Items $users -Kind Member -Title '請選擇成員'
                if ($u) { Invoke-UserInfoMenu -UserId $u.DistinguishedName }
                $null
            }
        }
    )
    Invoke-ListMenu -Rows $all -Kind Member -Title $title -ExportTitle $title -Extra $extra -Summary $summary
}

function Invoke-PrincipalGroupMenu {
    <# 使用者 / 電腦的所屬群組清單（可篩選、看成員、匯出） #>
    param([object[]]$Groups, [string]$Title, [string]$ExportTitle)
    Show-Result -Rows $Groups -Kind Group -Title $Title
    $extra = @(
        @{ Key = 'M'; Label = '查看某個群組的成員'; Action = {
                param($cur)
                $g = Select-OneItem -Items $cur -Kind Group -Title '請選擇群組'
                if ($g) { Invoke-MemberMenu -GroupId $g.DistinguishedName -Label $g.Name }
                $null
            }
        }
        @{ Key = 'D'; Label = '只看直接加入的群組'; Action = { param($cur, $full) @($full | Where-Object { $_.Via -like '直接*' }) } }
    )
    Invoke-ListMenu -Rows $Groups -Kind Group -Title $Title -ExportTitle $ExportTitle -Extra $extra
}

function Invoke-UserInfoMenu {
    param([Parameter(Mandatory)][string]$UserId)
    try { $r = Get-ADUserInfo -Identity $UserId }
    catch { Write-Status "查詢使用者失敗：$($_.Exception.Message)" -Level Error; return }
    $name = "$($r.User.SamAccountName)（$($r.User.Name)）"
    Show-InfoBlock -Info $r.Info -Title "使用者資訊：$name"
    $ex = Read-YesNo -Prompt '要匯出使用者資訊嗎？' -Default $false
    if ($ex) { Read-ExportChoice -Rows $r.Info -Kind Info -Title "使用者資訊_$($r.User.SamAccountName)" -Subtitle $name }
    Invoke-PrincipalGroupMenu -Groups $r.Groups -Title "所屬群組：$name" -ExportTitle "使用者所屬群組_$($r.User.SamAccountName)"
}

function Invoke-ComputerInfoMenu {
    param([Parameter(Mandatory)][string]$ComputerId)
    try { $r = Get-ADComputerInfo -Identity $ComputerId }
    catch { Write-Status "查詢電腦失敗：$($_.Exception.Message)" -Level Error; return }
    $name = $r.Computer.Name
    Show-InfoBlock -Info $r.Info -Title "電腦資訊：$name"
    $ex = Read-YesNo -Prompt '要匯出電腦資訊嗎？' -Default $false
    if ($ex) { Read-ExportChoice -Rows $r.Info -Kind Info -Title "電腦資訊_$name" -Subtitle $name }
    Invoke-PrincipalGroupMenu -Groups $r.Groups -Title "所屬群組：$name" -ExportTitle "電腦所屬群組_$name"
}

function Invoke-GroupMenu {
    $g = Select-GroupInteractive
    if (-not $g) { return }
    Write-Host ''
    Write-Status "群組：$($g.Name)　類型：$($g.Category)　範圍：$($g.Scope)　描述：$($g.Description)" -Level Note
    Invoke-MemberMenu -GroupId $g.DistinguishedName -Label $g.Name
}

function Invoke-CompareMenu {
    Write-Status '比較兩位使用者所屬的群組（含巢狀），常用於「新人的權限比照某位同事」。' -Level Info
    $a = Select-UserInteractive -Prompt '請輸入使用者 A（帳號或姓名），直接按 Enter 返回'
    if (-not $a) { return }
    $b = Select-UserInteractive -Prompt '請輸入使用者 B（帳號或姓名），直接按 Enter 返回'
    if (-not $b) { return }
    try { $r = Compare-ADUserGroup -UserA $a -UserB $b }
    catch { Write-Status "比較失敗：$($_.Exception.Message)" -Level Error; return }
    $na = $r.UserA.SamAccountName; $nb = $r.UserB.SamAccountName
    $diff = @($r.Rows | Where-Object { $_.Result -ne '兩者都有' })
    Write-Host ''
    Write-Status "A = $na（$($r.UserA.Name)，$($r.UserA.Department)）　B = $nb（$($r.UserB.Name)，$($r.UserB.Department)）" -Level Note
    $summary = "只有 A：{0} 個　只有 B：{1} 個　兩者都有：{2} 個" -f @($r.Rows | Where-Object { $_.Result -eq "只有 $na" }).Count,
        @($r.Rows | Where-Object { $_.Result -eq "只有 $nb" }).Count, @($r.Rows | Where-Object { $_.Result -eq '兩者都有' }).Count
    Write-Status $summary -Level Note
    $title = "群組比較：A=$na、B=$nb"
    if ($diff.Count -eq 0) { Write-Status '兩人的群組完全相同。' -Level Ok }
    Show-Result -Rows $diff -Kind Compare -Title "$title（只列差異）"
    $all = @($r.Rows)
    $extra = @(
        @{ Key = 'D'; Label = '只看差異'; Action = { param($cur, $full) @($full | Where-Object { $_.Result -ne '兩者都有' }) } }
        @{ Key = 'L'; Label = '列出全部'; Action = { param($cur, $full) @($full) } }
    )
    Invoke-ListMenu -Rows $all -Kind Compare -Title $title -ExportTitle "群組比較_$($na)_$($nb)" -Subtitle "A=$na（$($r.UserA.Name)）、B=$nb（$($r.UserB.Name)）" -Extra $extra
}

function Invoke-UserSearchMenu {
    while ($true) {
        $kw = Read-Choice '請輸入關鍵字（帳號、姓名、部門、職稱、Email、員工編號），直接按 Enter 返回'
        if (-not $kw) { return }
        try { $found = @(Find-ADUserByKeyword -Keyword $kw) }
        catch { Write-Status "搜尋失敗：$($_.Exception.Message)" -Level Error; continue }
        if ($found.Count -eq 0) { Write-Status "找不到符合「$kw」的使用者。" -Level Warn; continue }
        if ($found.Count -ge $script:MaxSearchResults) { Write-Status "符合的帳號太多，只列出前 $($script:MaxSearchResults) 筆，可輸入更完整的關鍵字。" -Level Warn }
        $title = "搜尋結果：$kw"
        Show-Result -Rows $found -Kind User -Title $title
        $extra = @(
            @{ Key = 'V'; Label = '查看某人的詳細資料'; Action = {
                    param($cur)
                    $u = Select-OneItem -Items $cur -Kind User -Title '請選擇使用者'
                    if ($u) { Invoke-UserInfoMenu -UserId $u.DistinguishedName }
                    $null
                }
            }
            @{ Key = 'A'; Label = '只看狀態異常帳號'; Action = { param($cur, $full) @($full | Where-Object { $_.Status -ne '正常' }) } }
        )
        Invoke-ListMenu -Rows $found -Kind User -Title $title -ExportTitle "帳號搜尋_$kw" -Extra $extra
    }
}

function Show-UserPathAccess {
    <# 顯示反查結果並詢問是否匯出 #>
    param([object[]]$Rows, [string]$User, [string]$Path)
    if ($Rows.Count -eq 0) {
        Write-Status "在此路徑上找不到 $User 可取得權限的項目（依 AD 群組判斷）。" -Level Warn
        return
    }
    Show-Result -Rows $Rows -Kind Access -Title "使用者 $User 在 $Path 的權限來源"
    if (@($Rows | Where-Object { $_.AccessType -eq '拒絕' -and $_.Certainty -eq '確定' }).Count -gt 0) {
        Write-Status '注意：此使用者有符合的「拒絕」權限，實際可能無法存取。' -Level Warn
    }
    if (Read-YesNo -Prompt '要匯出這份結果嗎？' -Default $false) {
        Read-ExportChoice -Rows $Rows -Kind Access -Title "使用者權限反查_$User" -Subtitle $Path
    }
}

function Invoke-UserPathAccessMenu {
    $u = Select-UserInteractive
    if (-not $u) { return }
    $path = Read-PathInput
    if (-not $path) { return }
    try {
        $sam = (Get-ADUserDetail -Identity $u).SamAccountName
        $rows = @(Find-UserPathAccess -Path $path -User $u)
        Show-UserPathAccess -Rows $rows -User $sam -Path $path
    }
    catch { Write-Status "反查失敗：$($_.Exception.Message)" -Level Error }
}

function Invoke-ComputerMenu {
    $c = Select-ComputerInteractive
    if ($c) { Invoke-ComputerInfoMenu -ComputerId $c }
}

function Invoke-GroupUsageMenu {
    $g = Select-GroupInteractive
    if (-not $g) { return }
    $path = Read-PathInput -Prompt '請輸入要從哪個資料夾開始找（例如 \\fileserver\share），直接按 Enter 返回'
    if (-not $path) { return }
    $depth = Read-DepthInput -Default 3 -Min 0
    $inherit = Read-YesNo -Prompt '是否也列出「繼承」來的權限？（選否只列出明確設定的資料夾，結果較精簡）' -Default $false
    try { $rows = @(Find-GroupFolderUsage -Group $g.DistinguishedName -Path $path -Depth $depth -IncludeInherited:$inherit) }
    catch { Write-Status "查詢失敗：$($_.Exception.Message)" -Level Error; return }
    $title = "群組 $($g.Name) 的權限位置：$path"
    if ($rows.Count -eq 0) { Write-Status "在 $path（往下 $depth 層）找不到給「$($g.Name)」的權限。" -Level Warn; return }
    Write-Status '提示：只比對這個群組本身；若它被加進其他群組，透過上層群組取得的權限不會列出。' -Level Hint
    Show-Result -Rows $rows -Kind Usage -Title $title
    Invoke-ListMenu -Rows $rows -Kind Usage -Title $title -ExportTitle "群組權限位置_$($g.Name)" -Subtitle "$path（深度 $depth）"
}

function Invoke-PathMenu {
    param([string]$Path)
    Write-Status "讀取「$Path」的權限中..." -Level Info
    try {
        $result = Get-PathPermission -Path $Path
    }
    catch {
        Write-Status "讀取權限失敗：$($_.Exception.Message)" -Level Error
        return 'next'
    }
    $perms = @($result.Permissions)
    $title = "權限清單：$Path"
    $sub = "擁有者：$($result.Owner)　繼承：$(if ($result.AreAccessRulesProtected) { '已中斷（不繼承上層）' } else { '有繼承上層' })"

    $showSummary = {
        Write-Host ''
        Write-Status $sub -Level Note
        Show-Result -Rows $perms -Kind Permission -Title $title
        $orphans = @($perms | Where-Object { $_.Category -eq '孤立 SID' })
        if ($orphans.Count -gt 0) { Write-Status "注意：有 $($orphans.Count) 筆孤立 SID（帳戶可能已刪除）。" -Level Warn }
        $denies = @($perms | Where-Object { $_.AccessType -eq '拒絕' })
        if ($denies.Count -gt 0) { Write-Status "注意：有 $($denies.Count) 筆「拒絕」權限，拒絕會優先於允許。" -Level Warn }
    }
    & $showSummary

    while ($true) {
        Show-Options @('1|選擇群組查看成員', '2|反查使用者權限', '3|掃描子資料夾', '4|匯出權限清單', '5|重新顯示', 'N|查詢其他路徑', 'B|回主選單', 'Q|離開')
        $c = (Read-Choice '請選擇').ToUpperInvariant()
        switch ($c) {
            '1' {
                $groups = @($perms | Where-Object { $_.CanExpand })
                if ($groups.Count -eq 0) { Write-Status '這個路徑上沒有可展開的 AD 群組。' -Level Warn; break }
                $g = Select-OneItem -Items $groups -Kind Permission -Title '請選擇要查詢的群組'
                if ($g) {
                    $gid = if ($g.DistinguishedName) { $g.DistinguishedName } else { $g.SamAccountName }
                    Invoke-MemberMenu -GroupId $gid -Label $g.Identity
                }
            }
            '2' {
                $u = Select-UserInteractive
                if (-not $u) { break }
                try {
                    $sam = (Get-ADUserDetail -Identity $u).SamAccountName
                    $rows = @(Find-UserPathAccess -Path $Path -User $u -PermissionResult $result)
                    Show-UserPathAccess -Rows $rows -User $sam -Path $Path
                }
                catch { Write-Status "反查失敗：$($_.Exception.Message)" -Level Error }
            }
            '3' {
                $depth = Read-DepthInput -Default 3 -Min 1
                $rows = @(Get-SubfolderPermissionDiff -Path $Path -Depth $depth)
                if ($rows.Count -eq 0) { Write-Status '所有子資料夾都是單純繼承上層權限，沒有差異。' -Level Ok }
                else {
                    Show-Result -Rows $rows -Kind Scan -Title "子資料夾權限差異：$Path"
                    if (Read-YesNo -Prompt '要匯出這份結果嗎？' -Default $false) { Read-ExportChoice -Rows $rows -Kind Scan -Title '子資料夾權限差異' -Subtitle $Path }
                }
            }
            '4' { Read-ExportChoice -Rows $perms -Kind Permission -Title '權限清單' -Subtitle "$Path　$sub" }
            '5' { & $showSummary }
            'N' { return 'next' }
            'B' { return 'menu' }
            'Q' { return 'quit' }
            default { Write-Status '請輸入選單上的代號。' -Level Warn }
        }
    }
}

function Invoke-PathFlow {
    <# 查詢路徑權限的流程；回傳 'menu'（回主選單）或 'quit'（離開） #>
    param([string]$Path)
    while ($true) {
        if (-not $Path) {
            $Path = Read-PathInput
            if (-not $Path) { return 'menu' }
        }
        elseif (-not (Test-Path -LiteralPath $Path)) {
            Write-Status "找不到路徑或沒有讀取權限：$Path" -Level Error
            $Path = $null
            continue
        }
        $r = Invoke-PathMenu -Path $Path
        $Path = $null
        if ($r -eq 'quit') { return 'quit' }
        if ($r -eq 'menu') { return 'menu' }
    }
}

function Show-MainMenu {
    Write-Section '主選單'
    $items = @(
        [pscustomobject]@{ Key = '1'; Label = '查詢路徑權限'; Hint = '誰有這個資料夾的權限' }
        [pscustomobject]@{ Key = '2'; Label = '查群組成員'; Hint = '輸入群組名稱，列出成員' }
        [pscustomobject]@{ Key = '3'; Label = '查使用者'; Hint = '個人資料與所屬群組' }
        [pscustomobject]@{ Key = '4'; Label = '比較兩位使用者'; Hint = '群組差異（新人權限比照同事）' }
        [pscustomobject]@{ Key = '5'; Label = '搜尋帳號'; Hint = '用姓名、部門、職稱、Email 找人' }
        [pscustomobject]@{ Key = '6'; Label = '反查使用者權限'; Hint = '某人在某個路徑有什麼權限' }
        [pscustomobject]@{ Key = '7'; Label = '查電腦帳號'; Hint = '作業系統、IP、狀態、所屬群組' }
        [pscustomobject]@{ Key = '8'; Label = '查群組使用處'; Hint = '群組被用在哪些資料夾' }
        [pscustomobject]@{ Key = 'Q'; Label = '離開'; Hint = '' }
    )
    foreach ($it in $items) {
        Write-Host '  [' -NoNewline
        Write-Host $it.Key -NoNewline -ForegroundColor Yellow
        Write-Host ('] ' + (Format-Cell $it.Label 18)) -NoNewline
        Write-Host $it.Hint -ForegroundColor DarkGray
    }
}

function Start-ADPermissionQuery {
    <#
    .SYNOPSIS
        互動式啟動：主選單可查詢路徑權限、群組成員、使用者 / 電腦資訊、比較使用者群組等。全程唯讀。
    .PARAMETER Path
        直接查詢這個路徑的權限（查完回到主選單）。
    #>
    [CmdletBinding()]
    param([string]$Path)

    $bar = '=' * 52
    Write-Host ''
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host '    AD 權限查詢工具（唯讀，不會修改 AD）' -ForegroundColor Cyan
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host '    任何清單都可以篩選、匯出；名稱可以只輸入一部分' -ForegroundColor DarkGray

    if (-not (Get-Command -Name Get-ADUser -ErrorAction SilentlyContinue)) {
        Write-Status '找不到 ActiveDirectory 模組。請先安裝 RSAT「Active Directory 網域服務工具」。' -Level Error
        Write-Status 'Windows 10/11：設定 > 應用程式 > 選用功能 > 新增「RSAT: Active Directory Domain Services...」' -Level Hint
        Write-Status 'Windows Server：Install-WindowsFeature RSAT-AD-PowerShell（需由系統管理員安裝）' -Level Hint
        return
    }

    if ($Path) {
        if ((Invoke-PathFlow -Path $Path) -eq 'quit') { return }
    }

    while ($true) {
        Show-MainMenu
        $c = (Read-Choice '請選擇').ToUpperInvariant()
        switch ($c) {
            '1' { if ((Invoke-PathFlow) -eq 'quit') { return } }
            '2' { Invoke-GroupMenu }
            '3' { $u = Select-UserInteractive; if ($u) { Invoke-UserInfoMenu -UserId $u } }
            '4' { Invoke-CompareMenu }
            '5' { Invoke-UserSearchMenu }
            '6' { Invoke-UserPathAccessMenu }
            '7' { Invoke-ComputerMenu }
            '8' { Invoke-GroupUsageMenu }
            'Q' { return }
            default { Write-Status '請輸入選單上的代號。' -Level Warn }
        }
    }
}

Export-ModuleMember -Function Start-ADPermissionQuery, Set-ADPermissionQueryOption, Get-PathPermission, Get-GroupMemberDetail,
Find-UserPathAccess, Get-SubfolderPermissionDiff, Export-QueryReport, Select-ByKeyword, Format-ForDisplay,
Convert-FileSystemRight, Convert-InheritanceToText, Resolve-AclIdentity, Get-PathAclInfo,
Find-ADGroupByName, Find-ADUserByKeyword, Find-ADComputerByName, Get-PrincipalGroupDetail, Get-ADUserInfo,
Get-ADComputerInfo, Compare-ADUserGroup, Find-GroupFolderUsage
