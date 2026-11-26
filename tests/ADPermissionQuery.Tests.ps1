#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# 功能測試：全部使用 Mock 的假 AD / 假 ACL，不會連線到任何真實的 AD。

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' 'ADPermissionQuery.psm1') -Force
    $global:SharePath = '\\fs01\share\Finance'
}

AfterAll {
    Remove-Module ADPermissionQuery -ErrorAction SilentlyContinue
}

Describe 'ADPermissionQuery' {

    BeforeEach {
        Set-ADPermissionQueryOption -NoGui -LogPath (Join-Path $TestDrive 'query.log') -InactiveDays 90
        $global:ADObjectFilters = New-Object System.Collections.Generic.List[string]

        Mock -ModuleName ADPermissionQuery Get-ADObject {
            if ($Filter) { $global:ADObjectFilters.Add([string]$Filter) }
            if ($Filter -match "objectSid -eq '([^']+)'") {
                $o = Find-FakeAD $Matches[1]
                if ($o -and $o.objectSid -eq $Matches[1]) { return $o }
                return
            }
            if ($Filter -match "sAMAccountName -eq '([^']+)'") {
                $o = Find-FakeAD $Matches[1]
                if ($o -and $o.sAMAccountName -eq $Matches[1]) { return $o }
                return
            }
            if ($Identity) { return (Find-FakeAD $Identity) }
        }
        Mock -ModuleName ADPermissionQuery Get-ADGroup {
            $o = Find-FakeAD $Identity
            if (-not $o -or @($o.objectClass)[-1] -ne 'group') { throw "找不到群組 $Identity" }
            [pscustomobject]@{ Name = $o.name; DistinguishedName = $o.distinguishedName; SamAccountName = $o.sAMAccountName; member = $global:GroupMembers[$o.distinguishedName] }
        }
        Mock -ModuleName ADPermissionQuery Get-ADGroupMember {
            foreach ($dn in @($global:GroupMembers[[string]$Identity])) { Find-FakeAD $dn }
        }
        Mock -ModuleName ADPermissionQuery Get-ADUser { Get-FakeADUser -Identity $Identity }
        Mock -ModuleName ADPermissionQuery Get-Acl { New-FakeAcl -Rules $global:FinanceRules -Owner 'CORP\FileAdmin' }
    }

    Context '權限文字轉換' {
        It '把 <Value> 轉成 <Expected>' -TestCases @(
            @{ Value = 2032127; Expected = '完全控制' }
            @{ Value = 1245631; Expected = '修改' }
            @{ Value = 1179817; Expected = '讀取和執行' }
            @{ Value = 1179785; Expected = '讀取' }
            @{ Value = 278; Expected = '寫入' }
            @{ Value = 1180095; Expected = '讀取和執行、寫入' }
            @{ Value = 268435456; Expected = '完全控制' }
            @{ Value = -536805376; Expected = '修改' }
            @{ Value = -1610612736; Expected = '讀取和執行' }
            @{ Value = 1; Expected = '特殊權限(0x1)' }
        ) {
            Convert-FileSystemRight -Rights $Value | Should -Be $Expected
        }

        It '套用範圍 IF=<IF> PF=<PF> → <Expected>' -TestCases @(
            @{ IF = 0; PF = 0; Expected = '只有此資料夾' }
            @{ IF = 3; PF = 0; Expected = '此資料夾、子資料夾及檔案' }
            @{ IF = 1; PF = 0; Expected = '此資料夾及子資料夾' }
            @{ IF = 2; PF = 0; Expected = '此資料夾及檔案' }
            @{ IF = 3; PF = 2; Expected = '只有子資料夾及檔案' }
            @{ IF = 1; PF = 2; Expected = '只有子資料夾' }
            @{ IF = 2; PF = 2; Expected = '只有檔案' }
            @{ IF = 3; PF = 1; Expected = '此資料夾、子資料夾及檔案（僅下一層）' }
        ) {
            Convert-InheritanceToText -InheritanceFlags $IF -PropagationFlags $PF | Should -Be $Expected
        }
    }

    Context '查詢路徑權限 Get-PathPermission' {
        BeforeEach { $script:r = Get-PathPermission -Path $global:SharePath }

        It '列出所有權限項目與擁有者' {
            $r.Permissions.Count | Should -Be 9
            $r.Owner | Should -Be 'CORP\FileAdmin'
        }
        It '正確分類 AD 群組、使用者並可展開群組' {
            $rw = $r.Permissions | Where-Object Identity -eq 'CORP\Finance-RW'
            $rw.Category | Should -Be '群組'
            $rw.Rights | Should -Be '修改'
            $rw.CanExpand | Should -BeTrue
            $rw.DistinguishedName | Should -Be 'CN=Finance-RW,OU=Groups,DC=corp,DC=local'
            ($r.Permissions | Where-Object Identity -eq 'CORP\jdoe').Category | Should -Be '使用者'
            ($r.Permissions | Where-Object CanExpand).Identity | Should -Be @('CORP\Finance-RW', 'CORP\Finance-RO', 'CORP\Interns')
        }
        It '內建帳戶不會去查 AD，也不可展開' {
            $adm = $r.Permissions | Where-Object Identity -eq 'BUILTIN\Administrators'
            $adm.Category | Should -Be '內建/特殊帳戶'
            $adm.CanExpand | Should -BeFalse
            ($r.Permissions | Where-Object Identity -eq 'CREATOR OWNER').AppliesTo | Should -Be '只有子資料夾及檔案'
            $global:ADObjectFilters | Where-Object { $_ -match 'S-1-5-32-544|S-1-5-18|S-1-3-0' } | Should -BeNullOrEmpty
        }
        It '找不到帳戶的 SID 標示為孤立 SID' {
            $o = $r.Permissions | Where-Object Identity -eq "$($global:DomainSid)-9999"
            $o.Category | Should -Be '孤立 SID'
            $o.Note | Should -Match '已被刪除'
        }
        It '拒絕權限標示為「拒絕」' {
            ($r.Permissions | Where-Object Identity -eq 'CORP\Interns').AccessType | Should -Be '拒絕'
        }
        It '伺服器本機帳戶不會被誤對應到同名的 AD 帳號' {
            $local = $r.Permissions | Where-Object Identity -eq 'FS01\jdoe'
            $local.Category | Should -Be '本機或其他網域帳戶'
            $local.CanExpand | Should -BeFalse
            $global:ADObjectFilters | Where-Object { $_ -match 'sAMAccountName' } | Should -BeNullOrEmpty
        }
        It '沒有 SID 時用帳戶名稱查詢，且會跳脫單引號' {
            Resolve-AclIdentity -Identity "CORP\o'neil" | Out-Null
            $global:ADObjectFilters | Should -Contain "sAMAccountName -eq 'o''neil'"
        }
        It '有指定 -Server 時會傳給 AD 查詢' {
            Set-ADPermissionQueryOption -Server 'dc01.corp.local'
            Get-PathPermission -Path $global:SharePath | Out-Null
            Should -Invoke -ModuleName ADPermissionQuery Get-ADObject -ParameterFilter { $Server -eq 'dc01.corp.local' }
        }
    }

    Context '群組成員 Get-GroupMemberDetail' {
        It '不展開巢狀時只列出直接成員' {
            $m = Get-GroupMemberDetail -Identity 'CN=Finance-RW,OU=Groups,DC=corp,DC=local'
            $m.Count | Should -Be 3
            ($m | Where-Object SamAccountName -eq 'alice').Name | Should -Be '王小美'
            ($m | Where-Object SamAccountName -eq 'alice').Department | Should -Be '財務部'
            ($m | Where-Object SamAccountName -eq 'alice').Email | Should -Be 'alice@corp.local'
            ($m | Where-Object Name -eq 'Finance-Managers').ObjectClass | Should -Be '群組'
        }
        It '展開巢狀群組、標示取得途徑，且不會因循環群組而無限迴圈' {
            $m = Get-GroupMemberDetail -Identity 'CN=Finance-RW,OU=Groups,DC=corp,DC=local' -Recurse
            $users = @($m | Where-Object ObjectClass -eq '使用者')
            $users.SamAccountName | Sort-Object | Should -Be @('alice', 'bob', 'carol')
            ($users | Where-Object SamAccountName -eq 'carol').Via | Should -Be 'Finance-RW > Finance-Managers'
            ($users | Where-Object SamAccountName -eq 'alice').Via | Should -Be 'Finance-RW；Finance-RW > Finance-Managers'
            Should -Invoke -ModuleName ADPermissionQuery Get-ADGroupMember -Times 2 -Exactly
        }
        It '顯示帳號狀態：停用、鎖定、密碼過期、久未登入' {
            $m = Get-GroupMemberDetail -Identity 'CN=Finance-RW,OU=Groups,DC=corp,DC=local' -Recurse
            ($m | Where-Object SamAccountName -eq 'alice').Status | Should -Be '正常'
            ($m | Where-Object SamAccountName -eq 'bob').Status | Should -Be '鎖定、密碼已過期'
            ($m | Where-Object SamAccountName -eq 'carol').Status | Should -Be '超過 90 天未登入'
            $ro = Get-GroupMemberDetail -Identity 'Finance-RO'
            ($ro | Where-Object SamAccountName -eq 'dave').Status | Should -Match '^停用'
            ($ro | Where-Object Name -eq 'PC01').ObjectClass | Should -Be '電腦'
        }
        It '久未登入天數可以調整' {
            Set-ADPermissionQueryOption -InactiveDays 365
            $m = Get-GroupMemberDetail -Identity 'CN=Finance-RW,OU=Groups,DC=corp,DC=local' -Recurse
            ($m | Where-Object SamAccountName -eq 'carol').Status | Should -Be '正常'
        }
        It 'Get-ADGroupMember 失敗時改用 member 屬性讀取' {
            Mock -ModuleName ADPermissionQuery Get-ADGroupMember { throw '超過 5000 筆上限' }
            $m = Get-GroupMemberDetail -Identity 'Finance-RO' -WarningAction SilentlyContinue
            $m.Count | Should -Be 2
            ($m | Where-Object SamAccountName -eq 'dave').Department | Should -Be '稽核室'
        }
        It '空群組回傳空集合' {
            @(Get-GroupMemberDetail -Identity 'Interns').Count | Should -Be 0
        }
    }

    Context '反查使用者權限 Find-UserPathAccess' {
        It '透過群組取得的權限會列出來源群組' {
            $a = Find-UserPathAccess -Path $global:SharePath -User 'CORP\alice'
            $sure = @($a | Where-Object Certainty -eq '確定')
            $sure.MatchedBy | Should -Be @('CORP\Finance-RW')
            $sure[0].Rights | Should -Be '修改'
            $sure[0].Reason | Should -Match '群組成員'
            ($a | Where-Object MatchedBy -eq 'BUILTIN\Administrators').Certainty | Should -Match '需確認'
        }
        It '直接授權給使用者本人、以及拒絕權限都會被找出' {
            $a = Find-UserPathAccess -Path $global:SharePath -User 'jdoe@corp.local'
            ($a | Where-Object Reason -eq '使用者本人').Rights | Should -Be '讀取'
            ($a | Where-Object MatchedBy -eq 'CORP\Interns').AccessType | Should -Be '拒絕'
            # 本機帳戶 FS01\jdoe 不應被當成同一人
            $a.MatchedBy | Should -Not -Contain 'FS01\jdoe'
        }
        It '沒有任何權限時回傳空集合' {
            Mock -ModuleName ADPermissionQuery Get-Acl { New-FakeAcl -Rules @($global:FinanceRules[3]) }
            @(Find-UserPathAccess -Path $global:SharePath -User 'dave').Count | Should -Be 0
        }
    }

    Context '子資料夾掃描 Get-SubfolderPermissionDiff' {
        BeforeEach {
            Mock -ModuleName ADPermissionQuery Get-ChildItem {
                [pscustomobject]@{ FullName = "$($global:SharePath)\2025" }
                [pscustomobject]@{ FullName = "$($global:SharePath)\薪資" }
                [pscustomobject]@{ FullName = "$($global:SharePath)\Locked" }
                [pscustomobject]@{ FullName = "$($global:SharePath)\NoAccess" }
            }
            Mock -ModuleName ADPermissionQuery Get-Acl -ParameterFilter { $LiteralPath -like '*\2025' } {
                New-FakeAcl -Rules @(New-TestRule 'CORP\Finance-RW' "$($global:DomainSid)-1101" 1245631 -Inherited $true)
            }
            Mock -ModuleName ADPermissionQuery Get-Acl -ParameterFilter { $LiteralPath -like '*\薪資' } {
                New-FakeAcl -Rules @(
                    New-TestRule 'CORP\Finance-RW' "$($global:DomainSid)-1101" 1245631 -Inherited $true
                    New-TestRule 'CORP\carol' "$($global:DomainSid)-1203" 2032127
                )
            }
            Mock -ModuleName ADPermissionQuery Get-Acl -ParameterFilter { $LiteralPath -like '*\Locked' } {
                New-FakeAcl -Protected $true -Rules @(New-TestRule 'CORP\Finance-RO' "$($global:DomainSid)-1102" 1179817)
            }
            Mock -ModuleName ADPermissionQuery Get-Acl -ParameterFilter { $LiteralPath -like '*\NoAccess' } { throw '存取被拒。' }
        }
        It '只列出有差異的資料夾' {
            $rows = Get-SubfolderPermissionDiff -Path $global:SharePath -Depth 2
            $rows.Folder | Should -Not -Contain "$($global:SharePath)\2025"
            $s = $rows | Where-Object Folder -like '*\薪資'
            $s.Identity | Should -Be 'CORP\carol'
            $s.Rights | Should -Be '完全控制'
            $s.InheritanceBroken | Should -Be '否'
            ($rows | Where-Object Folder -like '*\Locked').InheritanceBroken | Should -Be '是'
            ($rows | Where-Object Folder -like '*\NoAccess').Note | Should -Match '無法讀取'
        }
        It '掃描深度會傳給 Get-ChildItem' {
            Get-SubfolderPermissionDiff -Path $global:SharePath -Depth 5 | Out-Null
            Should -Invoke -ModuleName ADPermissionQuery Get-ChildItem -ParameterFilter { $Depth -eq 4 -and $Directory -and $Recurse }
        }
    }

    Context '關鍵字篩選 Select-ByKeyword' {
        BeforeAll {
            $script:rows = @(
                [pscustomobject]@{ Name = '王小美'; SamAccountName = 'alice'; Department = '財務部' }
                [pscustomobject]@{ Name = '林大明'; SamAccountName = 'Bob'; Department = '財務部' }
                [pscustomobject]@{ Name = '陳怡君'; SamAccountName = 'carol'; Department = '會計部' }
            )
        }
        It '不分大小寫' { (Select-ByKeyword -InputObject $rows -Keyword 'BOB').Name | Should -Be '林大明' }
        It '多個關鍵字需全部符合' { (Select-ByKeyword -InputObject $rows -Keyword '財務 alice').Name | Should -Be '王小美' }
        It '中文關鍵字' { @(Select-ByKeyword -InputObject $rows -Keyword '財務部').Count | Should -Be 2 }
        It '空白關鍵字回傳全部' { @(Select-ByKeyword -InputObject $rows -Keyword '  ').Count | Should -Be 3 }
        It '沒有符合回傳空' { @(Select-ByKeyword -InputObject $rows -Keyword 'zzz').Count | Should -Be 0 }
    }

    Context '匯出報表 Export-QueryReport' {
        It '匯出 CSV（含 BOM，Excel 開中文不亂碼）與 HTML' {
            $m = Get-GroupMemberDetail -Identity 'Finance-RW' -Recurse
            $files = Export-QueryReport -Kind Member -InputObject $m -Title '群組成員：CORP\Finance-RW' -Folder (Join-Path $TestDrive 'out') -Format Both
            $files.Count | Should -Be 2
            $csv = $files | Where-Object { $_ -like '*.csv' }
            $html = $files | Where-Object { $_ -like '*.html' }
            Split-Path $csv -Leaf | Should -Match '^群組成員：CORP_Finance-RW_\d{8}_\d{6}\.csv$'
            $bytes = [System.IO.File]::ReadAllBytes($csv)
            $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
            $data = Import-Csv -LiteralPath $csv
            $data.Count | Should -Be 5   # alice、bob、Finance-Managers、carol、Finance-RW(循環)
            ($data | Where-Object 帳號 -eq 'carol').姓名 | Should -Be '陳怡君'
            ($data | Where-Object 帳號 -eq 'carol').取得途徑 | Should -Be 'Finance-RW > Finance-Managers'
            $h = Get-Content -LiteralPath $html -Raw -Encoding UTF8
            $h | Should -Match '王小美'
            $h | Should -Match '<th>姓名</th>'
        }
        It 'HTML 會跳脫特殊字元' {
            $rows = @([pscustomobject]@{ Name = '<script>alert(1)</script>'; SamAccountName = 'x' })
            $f = Export-QueryReport -Kind Member -InputObject $rows -Title '<b>test</b>' -Folder $TestDrive -Format HTML
            $h = Get-Content -LiteralPath $f -Raw
            $h | Should -Not -Match '<script>'
            $h | Should -Not -Match '<b>test'
            $h | Should -Match '&lt;script&gt;'
        }
        It '沒有資料時仍產生檔案' {
            $f = Export-QueryReport -Kind Scan -InputObject @() -Title '空的' -Folder $TestDrive -Format Both
            $f | ForEach-Object { Test-Path -LiteralPath $_ | Should -BeTrue }
        }
    }

    Context '查詢紀錄 log' {
        BeforeEach {
            $script:logFile = Join-Path $TestDrive ("log-{0}.log" -f [guid]::NewGuid())
            Set-ADPermissionQueryOption -LogPath $logFile
        }
        It '每次查詢都寫入本機 log' {
            Get-PathPermission -Path $global:SharePath | Out-Null
            Get-GroupMemberDetail -Identity 'Finance-RO' | Out-Null
            $log = Get-Content -LiteralPath $logFile -Encoding UTF8
            $log.Count | Should -Be 2
            ($log[0] -split "`t")[3] | Should -Be '查詢路徑權限'
            ($log[0] -split "`t")[4] | Should -Be $global:SharePath
            ($log[1] -split "`t")[4] | Should -Be 'Finance-RO'
        }
        It '-NoLog 時不寫 log' {
            Set-ADPermissionQueryOption -NoLog
            Get-PathPermission -Path $global:SharePath | Out-Null
            Test-Path -LiteralPath $logFile | Should -BeFalse
            Set-ADPermissionQueryOption -NoLog:$false
        }
    }

    Context '互動式流程（模擬使用者輸入）' {
        BeforeEach {
            $global:HostOutput = New-Object System.Collections.Generic.List[string]
            Mock -ModuleName ADPermissionQuery Write-Host { $global:HostOutput.Add([string]$Object) }
            # 其他 Test-Path（log / 匯出資料夾）交給真正的指令（Pester 6 不會自動退回原指令）
            Mock -ModuleName ADPermissionQuery Test-Path { Microsoft.PowerShell.Management\Test-Path @PesterBoundParameters }
            Mock -ModuleName ADPermissionQuery Test-Path -ParameterFilter { $LiteralPath -eq $global:SharePath } { $true }
            Mock -ModuleName ADPermissionQuery Test-Path -ParameterFilter { $LiteralPath -eq '\\fs01\nope' } { $false }
            Mock -ModuleName ADPermissionQuery Get-ChildItem { [pscustomobject]@{ FullName = "$($global:SharePath)\Sub" } }
            $global:InputQueue = New-Object System.Collections.Generic.Queue[string]
            Mock -ModuleName ADPermissionQuery Read-Host {
                if ($global:InputQueue.Count -eq 0) { throw '測試輸入已用完（選單可能卡在迴圈）' }
                $global:InputQueue.Dequeue()
            }
        }

        It '完整走過：輸入路徑 → 選群組 → 篩選 → 匯出 → 反查 → 掃描 → 離開' {
            $out = Join-Path $TestDrive 'ui'
            @(
                '\\fs01\nope'          # 不存在的路徑
                "`"$($global:SharePath)`""  # 帶引號的路徑
                '1', '1', 'Y'          # 選群組 → 第 1 個 (Finance-RW) → 展開巢狀
                'F', '會計'             # 關鍵字篩選
                'A'                    # 只看異常
                'C'                    # 清除篩選
                'E', '1', $out         # 匯出 CSV
                'x'                    # 錯誤代號
                'B'                    # 返回
                '2', 'alice', 'y', '2', $out   # 反查並匯出 HTML
                '3', '2', 'n'          # 掃描子資料夾
                '4', '3', $out         # 匯出權限清單
                '1', '99', '2', 'n', 'B'   # 錯誤編號 → 第 2 個群組，不展開
                'N', 'q'               # 查詢其他路徑 → 離開
            ) | ForEach-Object { $global:InputQueue.Enqueue($_) }

            { Start-ADPermissionQuery } | Should -Not -Throw
            $global:InputQueue.Count | Should -Be 0

            $text = $global:HostOutput -join "`n"
            $text | Should -Match '找不到路徑或沒有讀取權限：\\\\fs01\\nope'
            $text | Should -Match '王小美'
            $text | Should -Match '陳怡君'
            $text | Should -Match '孤立 SID'
            $text | Should -Match '「拒絕」權限'
            $text | Should -Match '編號不正確'
            $text | Should -Match '吳志豪'
            $files = @(Get-ChildItem -LiteralPath $out -File)
            ($files | Where-Object Name -like '群組成員*.csv').Count | Should -Be 1
            ($files | Where-Object Name -like '使用者權限反查_alice*.html').Count | Should -Be 1
            ($files | Where-Object Name -like '權限清單*').Count | Should -Be 2
            Should -Invoke -ModuleName ADPermissionQuery Get-ADGroupMember -ParameterFilter { $Identity -eq 'CN=Finance-RO,OU=Groups,DC=corp,DC=local' } -Times 1 -Exactly
        }

        It '有 Out-GridView 時用視窗挑選群組' {
            Set-ADPermissionQueryOption -NoGui:$false
            # 模擬使用者在視窗中點選第 2 筆
            Mock -ModuleName ADPermissionQuery Out-GridView {
                if ($OutputMode -eq 'Single' -and $InputObject.'#' -eq 2) { $InputObject }
            }
            @('1', 'n', 'B', 'Q') | ForEach-Object { $global:InputQueue.Enqueue($_) }
            Start-ADPermissionQuery -Path $global:SharePath
            Should -Invoke -ModuleName ADPermissionQuery Get-ADGroup -ParameterFilter { $Identity -eq 'CN=Finance-RO,OU=Groups,DC=corp,DC=local' }
        }

        It '沒有 ActiveDirectory 模組時顯示安裝說明並結束' {
            Mock -ModuleName ADPermissionQuery Get-Command -ParameterFilter { $Name -eq 'Get-ADUser' } { $null }
            Start-ADPermissionQuery
            ($global:HostOutput -join "`n") | Should -Match 'RSAT'
            Should -Invoke -ModuleName ADPermissionQuery Read-Host -Times 0 -Exactly
        }
    }
}
