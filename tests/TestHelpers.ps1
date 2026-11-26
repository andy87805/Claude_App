# 測試共用：建立「假的」AD cmdlet 與 ACL，讓測試不需要真的連到 AD。
# 這些只是空殼函式，實際行為由各測試中的 Mock 決定。

foreach ($name in 'Get-ADObject', 'Get-ADUser', 'Get-ADGroup', 'Get-ADGroupMember') {
    if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
        $sb = [scriptblock]::Create(@"
function global:$name {
    [CmdletBinding()]
    param(`$Identity, `$Filter, `$Properties, `$Server)
    throw '$name 尚未被 Mock'
}
"@)
        . $sb
    }
}
if (-not (Get-Command -Name Get-Acl -ErrorAction SilentlyContinue)) {
    function global:Get-Acl {
        [CmdletBinding()]
        param($Path, $LiteralPath)
        throw 'Get-Acl 尚未被 Mock'
    }
}
if (-not (Get-Command -Name Out-GridView -ErrorAction SilentlyContinue)) {
    function global:Out-GridView {
        [CmdletBinding()]
        param([Parameter(ValueFromPipeline)]$InputObject, $Title, $OutputMode, [switch]$PassThru)
        begin { } process { } end { }
    }
}

$global:DomainSid = 'S-1-5-21-1000-2000-3000'

function New-TestRule {
    param(
        [string]$Name, [string]$Sid, [long]$Rights,
        [string]$Type = 'Allow', [bool]$Inherited = $false, [int]$IF = 3, [int]$PF = 0
    )
    [pscustomobject]@{ Name = $Name; Sid = $Sid; Rights = $Rights; Type = $Type; Inherited = $Inherited; IF = $IF; PF = $PF }
}

function New-FakeAcl {
    # 模擬 Get-Acl 回傳的物件：Access 屬性（帳戶名稱）＋ GetAccessRules()（SID）
    param([object[]]$Rules, [string]$Owner = 'BUILTIN\Administrators', [bool]$Protected = $false)
    $nameRules = @(foreach ($r in $Rules) {
            [pscustomobject]@{
                IdentityReference = $r.Name; FileSystemRights = $r.Rights; AccessControlType = $r.Type
                IsInherited = $r.Inherited; InheritanceFlags = $r.IF; PropagationFlags = $r.PF
            }
        })
    $sidRules = @(foreach ($r in $Rules) {
            [pscustomobject]@{
                IdentityReference = $r.Sid; FileSystemRights = $r.Rights; AccessControlType = $r.Type
                IsInherited = $r.Inherited; InheritanceFlags = $r.IF; PropagationFlags = $r.PF
            }
        })
    $acl = [pscustomobject]@{ Owner = $Owner; AreAccessRulesProtected = $Protected; Access = $nameRules; _SidRules = $sidRules }
    $acl | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value { param($a, $b, $t) $this._SidRules }
    return $acl
}

function New-FakeADObject {
    param([string]$Class, [string]$Sam, [string]$Name, [string]$Dn, [string]$Sid, [string]$DisplayName = '')
    [pscustomobject]@{
        # PowerShell 屬性名稱不分大小寫，$o.SamAccountName 與 $o.sAMAccountName 指向同一個屬性
        objectClass = @('top', $Class); sAMAccountName = $Sam; name = $Name
        distinguishedName = $Dn; objectSid = $Sid; SID = $Sid
        displayName = $DisplayName; description = ''
    }
}

# ---- 假的 AD 資料 ----
$global:FakeAD = @{}
function Add-FakeAD { param($o) $global:FakeAD[$o.distinguishedName] = $o }

$ou = 'OU=Groups,DC=corp,DC=local'
$uou = 'OU=Users,DC=corp,DC=local'
Add-FakeAD (New-FakeADObject group 'Finance-RW' 'Finance-RW' "CN=Finance-RW,$ou" "$($global:DomainSid)-1101")
Add-FakeAD (New-FakeADObject group 'Finance-RO' 'Finance-RO' "CN=Finance-RO,$ou" "$($global:DomainSid)-1102")
Add-FakeAD (New-FakeADObject group 'Interns' 'Interns' "CN=Interns,$ou" "$($global:DomainSid)-1103")
Add-FakeAD (New-FakeADObject group 'Finance-Managers' 'Finance-Managers' "CN=Finance-Managers,$ou" "$($global:DomainSid)-1104")
Add-FakeAD (New-FakeADObject user 'alice' 'Alice Wang' "CN=Alice Wang,$uou" "$($global:DomainSid)-1201" '王小美')
Add-FakeAD (New-FakeADObject user 'bob' 'Bob Lin' "CN=Bob Lin,$uou" "$($global:DomainSid)-1202" '林大明')
Add-FakeAD (New-FakeADObject user 'carol' 'Carol Chen' "CN=Carol Chen,$uou" "$($global:DomainSid)-1203" '陳怡君')
Add-FakeAD (New-FakeADObject user 'dave' 'Dave Wu' "CN=Dave Wu,$uou" "$($global:DomainSid)-1204" '吳志豪')
Add-FakeAD (New-FakeADObject user 'jdoe' 'John Doe' "CN=John Doe,$uou" "$($global:DomainSid)-1205" '杜約翰')
Add-FakeAD (New-FakeADObject computer 'PC01$' 'PC01' "CN=PC01,OU=Computers,DC=corp,DC=local" "$($global:DomainSid)-2001")

$global:GroupMembers = @{
    "CN=Finance-RW,$ou"       = @("CN=Alice Wang,$uou", "CN=Bob Lin,$uou", "CN=Finance-Managers,$ou")
    "CN=Finance-Managers,$ou" = @("CN=Carol Chen,$uou", "CN=Alice Wang,$uou", "CN=Finance-RW,$ou")   # 含循環
    "CN=Finance-RO,$ou"       = @("CN=Dave Wu,$uou", "CN=PC01,OU=Computers,DC=corp,DC=local")
    "CN=Interns,$ou"          = @()
}

$global:TestNow = Get-Date
$global:UserDetails = @{
    'alice' = @{ Department = '財務部'; Title = '專員'; mail = 'alice@corp.local'; telephoneNumber = '#101'; Enabled = $true; LockedOut = $false; PasswordExpired = $false; LastLogonDate = $global:TestNow.AddDays(-1); Groups = @('Finance-RW', 'Finance-Managers') }
    'bob'   = @{ Department = '財務部'; Title = '組長'; mail = 'bob@corp.local'; telephoneNumber = '#102'; Enabled = $true; LockedOut = $true; PasswordExpired = $true; LastLogonDate = $global:TestNow.AddDays(-3); Groups = @('Finance-RW') }
    'carol' = @{ Department = '會計部'; Title = '經理'; mail = 'carol@corp.local'; telephoneNumber = '#103'; Enabled = $true; LockedOut = $false; PasswordExpired = $false; LastLogonDate = $global:TestNow.AddDays(-200); Groups = @('Finance-Managers', 'Finance-RW') }
    'dave'  = @{ Department = '稽核室'; Title = '稽核'; mail = 'dave@corp.local'; telephoneNumber = '#104'; Enabled = $false; LockedOut = $false; PasswordExpired = $false; LastLogonDate = $global:TestNow.AddDays(-400); Groups = @('Finance-RO') }
    'jdoe'  = @{ Department = '資訊部'; Title = '工程師'; mail = 'jdoe@corp.local'; telephoneNumber = '#105'; Enabled = $true; LockedOut = $false; PasswordExpired = $false; LastLogonDate = $null; Groups = @('Interns') }
}

function Find-FakeAD {
    param([string]$Key)
    if ($global:FakeAD.ContainsKey($Key)) { return $global:FakeAD[$Key] }
    foreach ($o in $global:FakeAD.Values) { if ($o.sAMAccountName -eq $Key -or $o.objectSid -eq $Key) { return $o } }
    return $null
}

function Get-FakeADUser {
    param([string]$Identity)
    $o = Find-FakeAD $Identity
    if (-not $o -or @($o.objectClass)[-1] -ne 'user') { throw "Cannot find an object with identity: '$Identity'" }
    $d = $global:UserDetails[$o.sAMAccountName]
    $groupSids = @(foreach ($g in $d.Groups) { (Find-FakeAD $g).objectSid }) + "$($global:DomainSid)-513"
    [pscustomobject]@{
        Name = $o.name; SamAccountName = $o.sAMAccountName; DisplayName = $o.displayName; DistinguishedName = $o.distinguishedName
        SID = $o.objectSid; Department = $d.Department; Title = $d.Title; mail = $d.mail; telephoneNumber = $d.telephoneNumber; Office = ''
        Enabled = $d.Enabled; LockedOut = $d.LockedOut; PasswordExpired = $d.PasswordExpired; PasswordNeverExpires = $false
        PasswordLastSet = $global:TestNow.AddDays(-30); LastLogonDate = $d.LastLogonDate; tokenGroups = $groupSids
    }
}

# 標準測試路徑的 ACL
$global:FinanceRules = @(
    New-TestRule 'BUILTIN\Administrators' 'S-1-5-32-544' 2032127 -Inherited $true
    New-TestRule 'NT AUTHORITY\SYSTEM' 'S-1-5-18' 2032127 -Inherited $true
    New-TestRule 'CREATOR OWNER' 'S-1-3-0' 268435456 -Inherited $true -PF 2
    New-TestRule 'CORP\Finance-RW' "$($global:DomainSid)-1101" 1245631
    New-TestRule 'CORP\Finance-RO' "$($global:DomainSid)-1102" 1179817
    New-TestRule 'CORP\jdoe' "$($global:DomainSid)-1205" 1179785 -IF 0
    New-TestRule "$($global:DomainSid)-9999" "$($global:DomainSid)-9999" 1245631
    New-TestRule 'CORP\Interns' "$($global:DomainSid)-1103" 278 -Type Deny
    New-TestRule 'FS01\jdoe' 'S-1-5-21-7-8-9-1001' 1179817
)
