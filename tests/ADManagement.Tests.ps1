#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# 管理功能測試：全部使用 Mock 的假 AD，不會連線到任何真實的 AD。
# 「修改 AD」的指令（New-ADUser 等）也是 Mock，只記錄被呼叫的內容。

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'ADPermissionQuery.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot '..' 'ADManagement.psm1') -Force -Global
    $global:Python = Get-Command python3 -ErrorAction SilentlyContinue
    function global:New-TestSecure { param([string]$Text) ConvertTo-SecureString $Text -AsPlainText -Force }
    function global:New-Row { param([hashtable]$H) [pscustomobject]$H }
}

AfterAll {
    Remove-Module ADManagement, ADPermissionQuery -ErrorAction SilentlyContinue
}

Describe 'ADManagement' {
    BeforeEach {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')      # 每個測試都從同一份假 AD 開始
        Set-ADPermissionQueryOption -NoGui -LogPath (Join-Path $TestDrive 'query.log')
        $global:Changes = New-Object System.Collections.Generic.List[object]

        foreach ($m in 'ADManagement', 'ADPermissionQuery') {
            Mock -ModuleName $m Get-ADObject { Get-FakeADObjectForMgmt -Identity $Identity -Filter $Filter -SearchBase $SearchBase }
            Mock -ModuleName $m Get-ADGroup {
                if ($Filter) { return (Search-FakeAD -Class group -Filter $Filter) }
                Get-FakeADGroup -Identity $Identity
            }
            Mock -ModuleName $m Get-ADUser {
                if ($Filter -match "UserPrincipalName -eq '([^']+)'") {
                    $upn = $Matches[1]
                    foreach ($o in $global:FakeAD.Values) { if (@($o.objectClass)[-1] -eq 'user' -and "$($o.sAMAccountName)@corp.local" -eq $upn) { return $o } }
                    return
                }
                if ($Filter) { return (Search-FakeAD -Class user -Filter $Filter) }
                Get-FakeADUser -Identity $Identity
            }
            Mock -ModuleName $m Get-ADGroupMember { foreach ($dn in @($global:GroupMembers[[string]$Identity])) { Find-FakeAD $dn } }
        }
        Mock -ModuleName ADManagement Get-ADDomain { [pscustomobject]@{ DNSRoot = 'corp.local'; DistinguishedName = 'DC=corp,DC=local' } }
        Mock -ModuleName ADManagement Get-ADDefaultDomainPasswordPolicy { [pscustomobject]@{ MinPasswordLength = 8; ComplexityEnabled = $true } }

        # ---- 會修改 AD 的指令：只記錄，並更新假 AD ----
        Mock -ModuleName ADManagement New-ADGroup {
            $global:Changes.Add([pscustomobject]@{ Cmd = 'New-ADGroup'; Args = @{} + $PesterBoundParameters })
            $dn = "CN=$Name,$Path"
            $o = New-FakeADObject group $SamAccountName $Name $dn "S-1-5-21-9-$($global:Changes.Count)"
            Add-FakeAD $o
            $global:GroupMembers[$dn] = @()
            [pscustomobject]@{ ObjectGUID = $o.objectGUID; DistinguishedName = $dn }
        }
        Mock -ModuleName ADManagement New-ADUser {
            $global:Changes.Add([pscustomobject]@{ Cmd = 'New-ADUser'; Args = @{} + $PesterBoundParameters })
            $dn = "CN=$Name,$Path"
            $o = New-FakeADObject user $SamAccountName $Name $dn "S-1-5-21-9-$($global:Changes.Count)" $DisplayName
            Add-FakeAD $o
            [pscustomobject]@{ ObjectGUID = $o.objectGUID; DistinguishedName = $dn }
        }
        Mock -ModuleName ADManagement Add-ADGroupMember {
            $global:Changes.Add([pscustomobject]@{ Cmd = 'Add-ADGroupMember'; Group = [string]$Identity; Member = [string](@($Members)[0]) })
            if ([string]@($Members)[0] -eq 'FAIL-ME') { throw '模擬的 AD 錯誤' }
        }
        Mock -ModuleName ADManagement Remove-ADGroupMember { $global:Changes.Add([pscustomobject]@{ Cmd = 'Remove-ADGroupMember'; Group = [string]$Identity; Member = [string](@($Members)[0]) }) }
        Mock -ModuleName ADManagement Remove-ADUser { $global:Changes.Add([pscustomobject]@{ Cmd = 'Remove-ADUser'; Identity = [string]$Identity }) }
        Mock -ModuleName ADManagement Remove-ADGroup { $global:Changes.Add([pscustomobject]@{ Cmd = 'Remove-ADGroup'; Identity = [string]$Identity }) }
        Mock -ModuleName ADManagement Move-ADObject {
            $global:Changes.Add([pscustomobject]@{ Cmd = 'Move-ADObject'; Identity = [string]$Identity; TargetPath = [string]$TargetPath })
            # 更新假 AD 中的位置，還原測試才看得到搬移後的狀態
            foreach ($o in @($global:FakeAD.Values)) {
                if ($o.objectGUID -eq [string]$Identity) {
                    $global:FakeAD.Remove($o.distinguishedName)
                    $o.distinguishedName = "CN=$($o.name),$TargetPath"
                    $global:FakeAD[$o.distinguishedName] = $o
                }
            }
        }

        $global:Pw = New-TestSecure 'Welcome#2026'
    }

    Context '讀取 Excel / CSV' {
        It '產生的範本是標準的 .xlsx：資料工作表只有標題列，沒有預設值' {
            $f = New-ImportTemplate -Path (Join-Path $TestDrive 'tpl.xlsx')
            $book = Import-Spreadsheet -Path $f
            @($book.Keys) | Should -Be @('群組', '使用者', '群組成員', '移除成員', '搬移', '說明')
            foreach ($k in '群組', '使用者', '群組成員', '移除成員', '搬移') { @($book[$k]).Count | Should -Be 0 -Because "「$k」不應有預設資料" }
            @($book['說明']).Count | Should -BeGreaterThan 5
            if ($global:Python) {
                $py = "import openpyxl,sys; wb=openpyxl.load_workbook(sys.argv[1]); print('|'.join(wb.sheetnames)); print(wb['使用者']['A1'].value, wb['使用者']['A1'].font.b); print(','.join(str(wb[n].max_row) for n in ['群組','使用者','群組成員','移除成員','搬移']))"
                $out = & $global:Python.Source -c $py $f
                $out[0] | Should -Be '群組|使用者|群組成員|移除成員|搬移|說明'
                $out[1] | Should -Be '帳號* True'
                $out[2] | Should -Be '1,1,1,1,1'
            }
        }
        It '範本的說明不含任何實際網域資訊，產生範本時也不會查詢 AD' {
            Mock -ModuleName ADPermissionQuery Write-Host { }
            Mock -ModuleName ADManagement Get-DefaultExportFolder { $TestDrive }
            Mock -ModuleName ADPermissionQuery Read-Host { '' }
            Mock -ModuleName ADManagement Get-ADDomain { [pscustomobject]@{ DNSRoot = 'cms.secret.local'; DistinguishedName = 'DC=cms,DC=secret,DC=local' } }
            InModuleScope ADManagement { Invoke-TemplateMenu }
            Should -Invoke -ModuleName ADManagement Get-ADDomain -Times 0 -Exactly
            Should -Invoke -ModuleName ADManagement Get-ADObject -Times 0 -Exactly
            $f = Join-Path $TestDrive 'AD匯入範本.xlsx'
            Test-Path -LiteralPath $f | Should -BeTrue
            $all = (@((Import-Spreadsheet -Path $f)['說明']) | ForEach-Object { "$($_.'項目') $($_.'說明')" }) -join "`n"
            $all | Should -Not -Match 'cms|secret|corp\.local|DC=corp'
            $all | Should -Match 'DC=example,DC=com'
        }
        It '讀取一般 Excel 存出的檔案：共用字串、數字、日期、空白列、缺少的儲存格' -Skip:(-not (Get-Command python3 -ErrorAction SilentlyContinue)) {
            $f = Join-Path $TestDrive 'real.xlsx'
            $py = @'
import openpyxl, datetime, sys
from openpyxl.cell.rich_text import CellRichText, TextBlock
from openpyxl.cell.text import InlineFont
wb = openpyxl.Workbook(); ws = wb.active; ws.title = '使用者'
ws.append(['帳號*', '姓', '名', '員工編號', '帳號到期日', '描述'])
ws.append(['new01', '林', '小華', 123, datetime.date(2026, 12, 31), '第一列'])
ws.append([])
ws.append(['new02', None, None, '00123', None, CellRichText(['粗體', TextBlock(InlineFont(b=True), '文字')])])
ws['E2'].number_format = 'yyyy/mm/dd'
wb.create_sheet('說明').append(['不匯入'])
wb.save(sys.argv[1])
'@
            & (Get-Command python3).Source -c $py $f
            $book = Import-Spreadsheet -Path $f
            $rows = @($book['使用者'])
            $rows.Count | Should -Be 2
            $rows[0].'員工編號' | Should -Be '123'
            $rows[0].'帳號到期日' | Should -Be '2026-12-31'
            $rows[0].__Row | Should -Be 2
            $rows[1].__Row | Should -Be 4
            $rows[1].'姓' | Should -Be ''
            $rows[1].'員工編號' | Should -Be '00123'
            $rows[1].'描述' | Should -Be '粗體文字'
        }
        It '讀取 CSV（UTF-8 無 BOM、UTF-16）' {
            $f1 = Join-Path $TestDrive 'a.csv'
            [System.IO.File]::WriteAllText($f1, "群組,成員`r`nFinance-RW,carol`r`n,`r`nFinance-RO,""bob""`r`n", (New-Object System.Text.UTF8Encoding($false)))
            $r = @((Import-Spreadsheet -Path $f1)['CSV'])
            $r.Count | Should -Be 2
            $r[1].'成員' | Should -Be 'bob'
            $f2 = Join-Path $TestDrive 'b.csv'
            [System.IO.File]::WriteAllText($f2, "群組,成員`r`nFinance-RW,carol`r`n", [System.Text.Encoding]::Unicode)
            @((Import-Spreadsheet -Path $f2)['CSV'])[0].'群組' | Should -Be 'Finance-RW'
        }
        It '舊版 .xls 與不支援的格式會給清楚的錯誤' {
            $x = Join-Path $TestDrive 'old.xls'; Set-Content -LiteralPath $x -Value 'x'
            { Import-Spreadsheet -Path $x } | Should -Throw '*另存新檔*'
            $t = Join-Path $TestDrive 'a.txt'; Set-Content -LiteralPath $t -Value 'x'
            { Import-Spreadsheet -Path $t } | Should -Throw '*不支援*'
        }
        It '欄位名稱可用中文或英文，標題後的 * 會忽略，無法辨識的欄位會列出' {
            $rows = @([pscustomobject]@{ __Row = 2; '群組名稱*' = 'G1'; 'Description' = 'd'; '附註' = 'n'; '亂寫' = 'x' })
            $c = ConvertTo-FieldRows -Rows $rows -Kind Group -SheetName '群組'
            $c.Rows[0].Name | Should -Be 'G1'
            $c.Rows[0].Description | Should -Be 'd'
            $c.Rows[0].Info | Should -Be 'n'
            $c.Rows[0].Source | Should -Be '群組!2'
            $c.Unknown | Should -Be @('亂寫')
        }
    }

    Context '預覽（dry run）：新增群組' {
        It '各種情況分別標示為 將執行 / 略過 / 錯誤' {
            $rows = @(
                New-Row @{ Source = 'A'; Name = 'New-Group'; Path = 'OU=Groups,DC=corp,DC=local'; Description = '新群組'; Info = '申請單 1'; Members = 'alice;bob'; Scope = '萬用' }
                New-Row @{ Source = 'B'; Name = 'Finance-RW'; Path = 'OU=Groups,DC=corp,DC=local' }
                New-Row @{ Source = 'C'; Name = 'Bad-OU'; Path = 'OU=Nope,DC=corp,DC=local' }
                New-Row @{ Source = 'D'; Name = 'New-Group'; Path = 'OU=Groups,DC=corp,DC=local' }
                New-Row @{ Source = 'E'; Name = 'Bad[Name]'; Path = 'OU=Groups,DC=corp,DC=local' }
                New-Row @{ Source = 'F'; Name = 'Scope'; Path = 'OU=Groups,DC=corp,DC=local'; Scope = '亂填' }
                New-Row @{ Source = 'G'; Name = 'NoOU' }
            )
            $plan = New-ChangePlan -GroupRows $rows
            $s = @{}; foreach ($p in $plan | Where-Object Action -eq '新增群組') { $s[$p.Source] = $p }
            $s['A'].Status | Should -Be '將執行'
            $s['A'].Detail | Should -Match '範圍：萬用'
            $s['A'].Detail | Should -Match '附註：申請單 1'
            $s['B'].Status | Should -Be '略過'
            $s['C'].Reason | Should -Match 'OU 不存在'
            $s['D'].Reason | Should -Match '與 A 重複'
            $s['E'].Reason | Should -Match '不允許的字元'
            $s['F'].Reason | Should -Match '範圍「亂填」無法辨識'
            $s['G'].Reason | Should -Match '沒有指定 OU'
            $m = @($plan | Where-Object Action -eq '加入成員')
            $m.Count | Should -Be 2
            $m[0].Status | Should -Be '將執行'
            $m[0].Reason | Should -Match '建立後再加入'
            $plan.No | Should -Be (1..$plan.Count)
        }
        It '預設 OU 會套用到沒有填 OU 的列；OU 內同名物件會被擋下' {
            $plan = New-ChangePlan -GroupRows @(
                New-Row @{ Source = 'A'; Name = 'X1' }
                New-Row @{ Source = 'B'; Name = 'Finance-RO'; SamAccountName = 'Other-Sam'; Path = 'OU=Groups,DC=corp,DC=local' }
            ) -DefaultOU 'OU=Groups,DC=corp,DC=local'
            $plan[0].Status | Should -Be '將執行'
            $plan[1].Reason | Should -Match '已有名稱為「Finance-RO」的物件'
        }
        It '已存在的群組會略過，但仍處理要加入的成員' {
            $plan = New-ChangePlan -GroupRows @(New-Row @{ Source = 'A'; Name = 'Interns'; Path = 'OU=Groups,DC=corp,DC=local'; Members = 'carol' })
            $plan[0].Status | Should -Be '略過'
            $plan[1].Action | Should -Be '加入成員'
            $plan[1].Status | Should -Be '將執行'
        }
    }

    Context 'OU 可以用 / 分隔的路徑填寫' {
        It '<Text> → <Expected>' -TestCases @(
            @{ Text = '台北/財務部/帳號'; Expected = 'OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local' }
            @{ Text = 'corp.local/台北/財務部/帳號'; Expected = 'OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local' }
            @{ Text = '/台北/財務部/帳號/'; Expected = 'OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local' }
            @{ Text = '台北\財務部\帳號'; Expected = 'OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local' }
            @{ Text = ' 台北 / 財務部 / 帳號 '; Expected = 'OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local' }
            @{ Text = 'Builtin'; Expected = 'CN=Builtin,DC=corp,DC=local' }
            @{ Text = '台北/R&D, Lab'; Expected = 'OU=R&D\, Lab,OU=台北,DC=corp,DC=local' }
            @{ Text = 'OU=Groups,DC=corp,DC=local'; Expected = 'OU=Groups,DC=corp,DC=local' }
        ) {
            $r = InModuleScope ADManagement -Parameters @{ T = $Text } {
                param($T)
                $ctx = New-PlanContext
                Resolve-OUPath $ctx $T
            }
            $r.DN | Should -Be $Expected
            $r.Error | Should -BeNullOrEmpty
        }
        It '找不到某一層時，指出是哪一層' {
            $r = InModuleScope ADManagement { $ctx = New-PlanContext; Resolve-OUPath $ctx '台北/不存在/帳號' }
            $r.Error | Should -Be '找不到「不存在」這一層（台北/不存在）'
        }
        It '預覽：新增群組 / 使用者時接受路徑寫法，內容欄顯示路徑' {
            $plan = New-ChangePlan -GroupRows @(New-Row @{ Source = 'A'; Name = 'G-Path'; Path = '台北/財務部' }) `
                -UserRows @(
                    New-Row @{ Source = 'B'; SamAccountName = 'u.path'; Path = '台北/財務部/帳號' }
                    New-Row @{ Source = 'C'; SamAccountName = 'u.bad'; Path = '台北/財務部/不存在' }
                ) -Password $global:Pw
            $plan[0].Status | Should -Be '將執行'
            $plan[0].Data.Path | Should -Be 'OU=財務部,OU=台北,DC=corp,DC=local'
            $plan[0].Detail | Should -Match '^OU：台北/財務部；'
            $plan[1].Status | Should -Be '將執行'
            $plan[1].Data.Path | Should -Be 'OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local'
            $plan[2].Status | Should -Be '錯誤'
            $plan[2].Reason | Should -Match 'OU 有誤：台北/財務部/不存在，找不到「不存在」這一層'
        }
        It '預設 OU 也可以用路徑寫法' {
            $plan = New-ChangePlan -UserRows @(New-Row @{ Source = 'A'; SamAccountName = 'u.def' }) -Password $global:Pw -DefaultOU '台北/財務部/帳號'
            $plan[0].Status | Should -Be '將執行'
            $plan[0].Data.Path | Should -Be 'OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local'
        }
        It '執行時使用轉換後的 DN' {
            $plan = New-ChangePlan -UserRows @(New-Row @{ Source = 'A'; SamAccountName = 'u.run'; Path = '台北/財務部/帳號' }) -Password $global:Pw
            InModuleScope ADManagement -Parameters @{ Plan = $plan; Pw = $global:Pw; F = $TestDrive } { param($Plan, $Pw, $F) Invoke-ADChangePlan -Plan $Plan -Password $Pw -Folder $F } | Out-Null
            $global:Changes[0].Args.Path | Should -Be 'OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local'
        }
    }

    Context '預覽（dry run）：新增使用者' {
        It '帳號、UPN、主管、到期日、密碼原則都會檢查' {
            $rows = @(
                New-Row @{ Source = 'A'; SamAccountName = 'new.user'; Surname = '林'; GivenName = '小華'; Path = 'OU=Users,DC=corp,DC=local'; Manager = 'alice'; AccountExpirationDate = '2026-12-31'; Info = '附註文字'; MemberOf = 'Finance-RO' }
                New-Row @{ Source = 'B'; SamAccountName = 'alice'; Path = 'OU=Users,DC=corp,DC=local' }
                New-Row @{ Source = 'C'; SamAccountName = 'this-is-a-very-long-account'; Path = 'OU=Users,DC=corp,DC=local' }
                New-Row @{ Source = 'D'; SamAccountName = 'u4'; Path = 'OU=Users,DC=corp,DC=local'; Manager = 'nobody' }
                New-Row @{ Source = 'E'; SamAccountName = 'u5'; Path = 'OU=Users,DC=corp,DC=local'; AccountExpirationDate = '31/12/2026' }
                New-Row @{ Source = 'F'; SamAccountName = 'u6'; Path = 'OU=Users,DC=corp,DC=local'; Enabled = '也許' }
                New-Row @{ Source = 'G'; SamAccountName = 'u7'; DisplayName = 'Alice Wang'; Path = 'OU=Users,DC=corp,DC=local' }
            )
            $plan = New-ChangePlan -UserRows $rows -Password $global:Pw
            $s = @{}; foreach ($p in $plan | Where-Object Action -eq '新增使用者') { $s[$p.Source] = $p }
            $s['A'].Status | Should -Be '將執行'
            $s['A'].Target | Should -Be '林小華（new.user）'
            $s['A'].Detail | Should -Match 'UPN：new.user@corp.local'
            $s['A'].Detail | Should -Match '可使用到 2026-12-31'
            $s['A'].Data.AccountExpirationDate | Should -Be ([datetime]'2027-01-01')
            $s['A'].Data.Manager | Should -Be 'CN=Alice Wang,OU=Users,DC=corp,DC=local'
            $s['B'].Status | Should -Be '略過'
            $s['C'].Reason | Should -Match '超過 20 個字元'
            $s['D'].Reason | Should -Match '找不到主管帳號'
            $s['E'].Reason | Should -Match '格式不正確'
            $s['F'].Reason | Should -Match '啟用欄位'
            $s['G'].Reason | Should -Match '已有名稱為「Alice Wang」'
            ($plan | Where-Object Action -eq '加入成員').Target | Should -Be 'Finance-RO'
        }
        It '初始密碼不符合網域原則時，每個新帳號都會顯示原因' {
            $plan = New-ChangePlan -UserRows @(New-Row @{ Source = 'A'; SamAccountName = 'abcuser'; Path = 'OU=Users,DC=corp,DC=local' }) -Password (New-TestSecure 'abcuser1')
            $plan[0].Status | Should -Be '錯誤'
            $plan[0].Reason | Should -Match '大寫、小寫、數字、符號其中 3 種'
            $plan[0].Reason | Should -Match '不能包含帳號名稱'
            $plan2 = New-ChangePlan -UserRows @(New-Row @{ Source = 'A'; SamAccountName = 'u1'; Path = 'OU=Users,DC=corp,DC=local' }) -Password (New-TestSecure 'Ab1!')
            $plan2[0].Reason | Should -Match '至少要 8 個字元'
            $plan3 = New-ChangePlan -UserRows @(New-Row @{ Source = 'A'; SamAccountName = 'u1'; Path = 'OU=Users,DC=corp,DC=local' })
            $plan3[0].Reason | Should -Match '沒有輸入初始密碼'
        }
        It '主管也是這次新增的人時可以引用' {
            $plan = New-ChangePlan -UserRows @(
                New-Row @{ Source = 'A'; SamAccountName = 'boss1'; Path = 'OU=Users,DC=corp,DC=local' }
                New-Row @{ Source = 'B'; SamAccountName = 'staff1'; Path = 'OU=Users,DC=corp,DC=local'; Manager = 'boss1' }
            ) -Password $global:Pw
            $plan[1].Status | Should -Be '將執行'
            $plan[1].Data.Manager | Should -Be 'boss1'
        }
    }

    Context '預覽（dry run）：加入 / 移除成員' {
        It '已是成員、找不到、不是群組、重複都會標示' {
            $add = @(
                New-Row @{ Source = 'A'; Group = 'Finance-RW'; Member = 'alice' }
                New-Row @{ Source = 'B'; Group = 'Finance-RW'; Member = 'dave' }
                New-Row @{ Source = 'C'; Group = 'Finance-RW'; Member = 'nobody' }
                New-Row @{ Source = 'D'; Group = 'alice'; Member = 'dave' }
                New-Row @{ Source = 'E'; Group = 'Finance-RW'; Member = 'CORP\dave' }
                New-Row @{ Source = 'F'; Group = 'Finance-RO'; Member = 'PC02' }
                New-Row @{ Source = 'G'; Group = 'Finance-RW'; Member = 'Finance-RW' }
            )
            $remove = @(
                New-Row @{ Source = 'H'; Group = 'Finance-RO'; Member = 'dave' }
                New-Row @{ Source = 'I'; Group = 'Finance-RO'; Member = 'alice' }
            )
            $plan = New-ChangePlan -AddMemberRows $add -RemoveMemberRows $remove
            $s = @{}; foreach ($p in $plan) { $s[$p.Source] = $p }
            $s['A'].Reason | Should -Be '已經是成員'
            $s['B'].Status | Should -Be '將執行'
            $s['B'].Detail | Should -Be '成員：dave（使用者）'
            $s['C'].Reason | Should -Match '找不到成員'
            $s['D'].Reason | Should -Match '不是群組'
            $s['E'].Reason | Should -Match '與 B 重複'
            $s['F'].Status | Should -Be '將執行'
            $s['F'].Detail | Should -Be '成員：PC02$（電腦）'
            $s['G'].Reason | Should -Match '不能加入自己'
            $s['H'].Action | Should -Be '移除成員'
            $s['H'].Status | Should -Be '將執行'
            $s['I'].Reason | Should -Match '不是這個群組的直接成員'
        }
        It '預覽過程完全不會呼叫任何修改 AD 的指令' {
            New-ChangePlan -GroupRows @(New-Row @{ Source = 'A'; Name = 'G1'; Path = 'OU=Groups,DC=corp,DC=local'; Members = 'alice' }) `
                -UserRows @(New-Row @{ Source = 'B'; SamAccountName = 'u1'; Path = 'OU=Users,DC=corp,DC=local'; MemberOf = 'G1' }) `
                -AddMemberRows @(New-Row @{ Source = 'C'; Group = 'Finance-RW'; Member = 'dave' }) `
                -RemoveMemberRows @(New-Row @{ Source = 'D'; Group = 'Finance-RO'; Member = 'dave' }) `
                -MoveRows @(New-Row @{ Source = 'E'; Object = 'bob'; SourceOU = '台北'; TargetOU = '台北/財務部' }) -Password $global:Pw | Out-Null
            foreach ($c in 'New-ADGroup', 'New-ADUser', 'Add-ADGroupMember', 'Remove-ADGroupMember', 'Remove-ADUser', 'Remove-ADGroup', 'Move-ADObject') {
                Should -Invoke -ModuleName ADManagement $c -Times 0 -Exactly
            }
            $global:Changes.Count | Should -Be 0
        }
    }


    Context '搬移物件' {
        It '預覽：查出實際位置；不在 Excel 填的 OU 時標示「需確認」' {
            Add-FakeAD (New-FakeADObject user 'alice2' 'Alice Wang' 'CN=Alice Wang,OU=台北,DC=corp,DC=local' 'S-1-5-21-9-77')
            (Find-FakeAD 'jdoe').ProtectedFromAccidentalDeletion = $true
            $rows = @(
                New-Row @{ Source = 'A'; Object = 'bob'; TargetOU = '台北/財務部/帳號' }
                New-Row @{ Source = 'B'; Object = 'carol'; SourceOU = 'Users'; TargetOU = '台北/財務部/帳號' }
                New-Row @{ Source = 'C'; Object = 'dave'; SourceOU = '台北/業務部'; TargetOU = '台北/財務部/帳號' }
                New-Row @{ Source = 'D'; Object = 'PC01'; TargetOU = 'Computers' }
                New-Row @{ Source = 'E'; Object = 'nobody'; TargetOU = '台北' }
                New-Row @{ Source = 'F'; Object = 'Finance-RO'; TargetOU = '台北/不存在' }
                New-Row @{ Source = 'G'; Object = 'CORP\bob'; TargetOU = '台北' }
                New-Row @{ Source = 'H'; Object = 'jdoe'; TargetOU = '台北' }
                New-Row @{ Source = 'I'; Object = 'Finance-RW'; TargetOU = '台北' }
                New-Row @{ Source = 'J'; Object = 'alice'; TargetOU = '台北' }
                New-Row @{ Source = 'K'; Object = 'Alice Wang'; TargetOU = '台北/財務部' }
                New-Row @{ Source = 'L'; Object = 'carol'; TargetOU = '台北' }
                New-Row @{ Source = 'M'; Object = 'PC02'; SourceOU = '台北/不存在'; TargetOU = '台北' }
            )
            $plan = New-ChangePlan -MoveRows $rows
            $s = @{}; foreach ($p in $plan) { $s[$p.Source] = $p }
            $s['A'].Status | Should -Be '將執行'
            $s['A'].Target | Should -Be 'Bob Lin（bob，使用者）'
            $s['A'].Detail | Should -Be '從 Users → 到 台北/財務部/帳號'
            $s['A'].Data.TargetPath | Should -Be 'OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local'
            $s['B'].Status | Should -Be '將執行'
            $s['C'].Status | Should -Be '需確認'
            $s['C'].Reason | Should -Be 'Excel 填的目前 OU 是「台北/業務部」，但物件實際在「Users」'
            $s['D'].Status | Should -Be '略過'
            $s['D'].Reason | Should -Be '已經在目標 OU'
            $s['D'].Target | Should -Be 'PC01（PC01$，電腦）'
            $s['E'].Reason | Should -Be '找不到物件：nobody'
            $s['F'].Reason | Should -Match '目標 OU 有誤：台北/不存在，找不到「不存在」這一層'
            $s['G'].Reason | Should -Be '與 A 重複'
            $s['H'].Reason | Should -Match '防止意外刪除'
            $s['I'].Status | Should -Be '將執行'
            $s['I'].Target | Should -Be 'Finance-RW（群組）'
            $s['J'].Reason | Should -Be '目標 OU 已有名稱為「Alice Wang」的物件'
            $s['K'].Reason | Should -Match '找到 2 個名稱為「Alice Wang」的物件（位置：Users、台北），請改填帳號或 DN'
            $s['L'].Reason | Should -Be '與 B 重複'
            $s['M'].Status | Should -Be '需確認'
            $s['M'].Reason | Should -Match 'Excel 填的目前 OU「台北/不存在」不存在，物件實際在「Computers」'
        }
        It '不能搬移這次才要新增的物件' {
            $plan = New-ChangePlan -UserRows @(New-Row @{ Source = 'A'; SamAccountName = 'brand.new'; Path = 'Users' }) `
                -MoveRows @(New-Row @{ Source = 'B'; Object = 'brand.new'; TargetOU = '台北' }) -Password $global:Pw
            ($plan | Where-Object Source -eq 'B').Reason | Should -Be '這是這次要新增的物件，請直接在新增時填目標 OU'
        }
        It 'Excel 標題可寫「目前OU」「目標OU」（不分空白），工作表「搬移」會被辨識' {
            $rows = @([pscustomobject]@{ __Row = 2; '物件*' = 'bob'; '目前OU' = 'Users'; '目標OU*' = '台北' })
            $c = ConvertTo-FieldRows -Rows $rows -Kind Move -SheetName '搬移'
            $c.Rows[0].Object | Should -Be 'bob'
            $c.Rows[0].SourceOU | Should -Be 'Users'
            $c.Rows[0].TargetOU | Should -Be '台北'
            $c.Unknown | Should -BeNullOrEmpty
            InModuleScope ADManagement { Get-SheetKind '搬移' } | Should -Be 'Move'
        }
        It '執行：搬移排在最後；還原清單可以搬回原本的 OU' {
            $plan = New-ChangePlan -AddMemberRows @(New-Row @{ Source = 'A'; Group = 'Finance-RO'; Member = 'bob' }) `
                -MoveRows @(New-Row @{ Source = 'B'; Object = 'bob'; TargetOU = '台北/財務部/帳號' })
            $bobGuid = (Find-FakeAD 'bob').objectGUID
            $res = InModuleScope ADManagement -Parameters @{ Plan = $plan; F = $TestDrive } { param($Plan, $F) Invoke-ADChangePlan -Plan $Plan -Folder $F }
            $global:Changes.Cmd | Should -Be @('Add-ADGroupMember', 'Move-ADObject')
            $global:Changes[0].Member | Should -Be 'CN=Bob Lin,OU=Users,DC=corp,DC=local'   # 成員變更用搬移前的 DN
            $global:Changes[1].Identity | Should -Be $bobGuid
            $global:Changes[1].TargetPath | Should -Be 'OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local'
            $undo = @(Import-Csv -LiteralPath $res.UndoPath)
            $undo[0].'動作' | Should -Be '搬移物件'
            $undo[0].'目標 OU' | Should -Be 'OU=Users,DC=corp,DC=local'
            $undoPlan = New-UndoPlan -Path $res.UndoPath
            $mv = $undoPlan | Where-Object Action -eq '搬移物件'
            $mv.Status | Should -Be '將執行'
            $mv.Detail | Should -Be '從 台北/財務部/帳號 → 到 Users'
        }
        It '互動：不在指定 OU 的物件可以逐筆確認，只搬選擇「是」的' {
            $global:HostOutput = New-Object System.Collections.Generic.List[string]
            $global:HostLine = ''
            $global:InputQueue = New-Object System.Collections.Generic.Queue[object]
            foreach ($m in 'ADManagement', 'ADPermissionQuery') {
                Mock -ModuleName $m Write-Host {
                    if ($NoNewline) { $global:HostLine += [string]$Object }
                    else { $global:HostOutput.Add($global:HostLine + [string]$Object); $global:HostLine = '' }
                }
                Mock -ModuleName $m Read-Host {
                    $global:HostOutput.Add("[提問] $Prompt")      # 提示字也記錄下來，才能檢查問了什麼
                    if ($global:InputQueue.Count -eq 0) { throw '測試輸入已用完' }
                    $global:InputQueue.Dequeue()
                }
            }
            Mock -ModuleName ADManagement Get-DefaultExportFolder { Join-Path $TestDrive 'out' }
            Mock -ModuleName ADPermissionQuery Get-DefaultExportFolder { Join-Path $TestDrive 'out' }
            $csv = Join-Path $TestDrive 'move.csv'
            [System.IO.File]::WriteAllText($csv, "物件,目前 OU,目標 OU`r`nbob,台北/業務部,台北/財務部`r`ncarol,台北/業務部,台北/財務部`r`ndave,,台北/財務部`r`n", (New-Object System.Text.UTF8Encoding($true)))
            @('6', $csv, '5', 'O', 'y', 'n', 'X', 'YES', 'Q') | ForEach-Object { $global:InputQueue.Enqueue($_) }
            Start-ADManagement
            $global:InputQueue.Count | Should -Be 0
            $text = $global:HostOutput -join "`n"
            $text | Should -Match '有 2 筆物件不在 Excel 填的「目前 OU」'
            $text | Should -Match '「Bob Lin（bob，使用者）」目前在「Users」，要搬到「台北/財務部」嗎？'
            $text | Should -Match '需確認 2'
            $moved = @($global:Changes | Where-Object Cmd -eq 'Move-ADObject')
            $moved.Count | Should -Be 2       # bob（確認搬）+ dave（沒填目前 OU，直接搬）；carol 選擇不搬
            $moved.Identity | Should -Not -Contain (Find-FakeAD 'carol').objectGUID
        }
        It '互動：單筆搬移，可一次輸入多個物件' {
            $global:InputQueue = New-Object System.Collections.Generic.Queue[object]
            foreach ($m in 'ADManagement', 'ADPermissionQuery') {
                Mock -ModuleName $m Write-Host { }
                Mock -ModuleName $m Read-Host { if ($global:InputQueue.Count -eq 0) { throw '測試輸入已用完' }; $global:InputQueue.Dequeue() }
            }
            Mock -ModuleName ADManagement Get-DefaultExportFolder { Join-Path $TestDrive 'out2' }
            @('5', 'bob;PC02', '台北/財務部', 'X', 'YES', 'Q') | ForEach-Object { $global:InputQueue.Enqueue($_) }
            Start-ADManagement
            $global:InputQueue.Count | Should -Be 0
            @($global:Changes | Where-Object Cmd -eq 'Move-ADObject').Count | Should -Be 2
        }
    }

    Context '執行與還原' {
        It '依順序執行（先建群組、再建使用者、最後加成員），單筆失敗不影響其他' {
            $plan = New-ChangePlan -GroupRows @(New-Row @{ Source = 'A'; Name = 'G-New'; Path = 'OU=Groups,DC=corp,DC=local'; Description = 'D1'; Info = 'N1' }) `
                -UserRows @(New-Row @{ Source = 'B'; SamAccountName = 'u.new'; Surname = '王'; GivenName = '五'; Path = 'OU=Users,DC=corp,DC=local'; MemberOf = 'G-New'; AccountExpirationDate = '2026-12-31'; Enabled = '否' }) `
                -AddMemberRows @(New-Row @{ Source = 'C'; Group = 'Finance-RW'; Member = 'dave' }) -Password $global:Pw
            # 模擬一筆執行時才失敗的變更
            ($plan | Where-Object Source -eq 'C').Data.Member = 'FAIL-ME'
            $res = InModuleScope ADManagement -Parameters @{ Plan = $plan; Pw = $global:Pw; F = $TestDrive } { param($Plan, $Pw, $F) Invoke-ADChangePlan -Plan $Plan -Password $Pw -Folder $F }
            $global:Changes.Cmd | Should -Be @('New-ADGroup', 'New-ADUser', 'Add-ADGroupMember', 'Add-ADGroupMember')
            $g = $global:Changes[0].Args
            $g.Description | Should -Be 'D1'
            $g.OtherAttributes.info | Should -Be 'N1'
            $g.GroupScope | Should -Be 'Global'
            $u = $global:Changes[1].Args
            $u.ChangePasswordAtLogon | Should -BeTrue
            $u.Enabled | Should -BeFalse
            $u.AccountExpirationDate | Should -Be ([datetime]'2027-01-01')
            $u.UserPrincipalName | Should -Be 'u.new@corp.local'
            $global:Changes[2].Group | Should -Be 'G-New'
            ($res.Items | Where-Object Source -eq 'C').Result | Should -Be '失敗'
            ($res.Items | Where-Object Source -eq 'C').Message | Should -Match '模擬的 AD 錯誤'
            @($res.Items | Where-Object Result -eq '成功').Count | Should -Be 3
            $res.ReportFiles.Count | Should -Be 2
            $undo = Import-Csv -LiteralPath $res.UndoPath
            $undo.'動作' | Should -Be @('移除成員', '刪除使用者', '刪除群組')
            $undo[1].ObjectGUID | Should -Not -BeNullOrEmpty
        }
        It '用還原清單復原：只刪除 GUID 相符的物件，已不存在的會略過' {
            $plan = New-ChangePlan -GroupRows @(New-Row @{ Source = 'A'; Name = 'G-Undo'; Path = 'OU=Groups,DC=corp,DC=local'; Members = 'alice' }) -Password $global:Pw
            $res = InModuleScope ADManagement -Parameters @{ Plan = $plan; F = $TestDrive } { param($Plan, $F) Invoke-ADChangePlan -Plan $Plan -Folder $F }
            # 加一筆已經不存在的物件
            Add-Content -LiteralPath $res.UndoPath -Value '"刪除使用者","","","ghost","00000000-0000-0000-0000-000000000001","新增使用者","2026-01-01 00:00:00"' -Encoding UTF8
            $global:GroupMembers['CN=G-Undo,OU=Groups,DC=corp,DC=local'] = @('CN=Alice Wang,OU=Users,DC=corp,DC=local')
            $undoPlan = New-UndoPlan -Path $res.UndoPath
            ($undoPlan | Where-Object Action -eq '移除成員').Status | Should -Be '將執行'
            $del = $undoPlan | Where-Object Action -eq '刪除群組'
            $del.Status | Should -Be '將執行'
            $del.Reason | Should -Match '目前有 1 個成員'
            ($undoPlan | Where-Object Target -eq 'ghost').Status | Should -Be '略過'
            $global:Changes.Clear()
            InModuleScope ADManagement -Parameters @{ Plan = $undoPlan; F = $TestDrive } { param($Plan, $F) Invoke-ADChangePlan -Plan $Plan -Folder $F } | Out-Null
            $global:Changes.Cmd | Should -Be @('Remove-ADGroupMember', 'Remove-ADGroup')
            $global:Changes[1].Identity | Should -Be $del.Data.Identity
        }
    }

    Context '互動流程（模擬使用者輸入）' {
        BeforeEach {
            $global:HostOutput = New-Object System.Collections.Generic.List[string]
            $global:HostLine = ''
            $global:InputQueue = New-Object System.Collections.Generic.Queue[object]
            foreach ($m in 'ADManagement', 'ADPermissionQuery') {
                Mock -ModuleName $m Write-Host {
                    if ($NoNewline) { $global:HostLine += [string]$Object }
                    else { $global:HostOutput.Add($global:HostLine + [string]$Object); $global:HostLine = '' }
                }
                Mock -ModuleName $m Read-Host {
                    if ($global:InputQueue.Count -eq 0) { throw '測試輸入已用完（選單可能卡在迴圈）' }
                    $v = $global:InputQueue.Dequeue()
                    if ($AsSecureString) { if ("$v") { return (New-TestSecure ([string]$v)) } else { return (New-Object System.Security.SecureString) } }
                    return $v
                }
            }
            Mock -ModuleName ADManagement Get-DefaultExportFolder { Join-Path $TestDrive 'out' }
            Mock -ModuleName ADPermissionQuery Get-DefaultExportFolder { Join-Path $TestDrive 'out' }
        }

        It 'Excel 匯入：先預覽；輸入小寫 yes 不會執行，輸入大寫 YES 才執行' {
            # 自己產生一份有資料的 Excel（範本本身沒有預設資料）
            $tpl = Join-Path $TestDrive 'import.xlsx'
            $sheets = @(
                @{ Name = '群組'; Header = @('群組名稱*', '帳號', 'OU*', '範圍', '類型', '描述', '附註', '成員'); Rows = @(, @('財務部-檔案讀寫', 'FIN-FS-RW', 'Groups', '網域本機', '安全性', '財務部共用資料夾讀寫', '申請單 2026-001', 'alice;bob')) }
                @{ Name = '使用者'; Header = @('帳號*', '姓', '名', 'OU*', '部門', '主管', '描述', '附註', '啟用', '加入群組'); Rows = @(, @('wang.dm', '王', '大明', 'Users', '財務部', 'alice', '新進人員', '到職日 2026-12-01', '是', 'FIN-FS-RW')) }
                @{ Name = '群組成員'; Header = @('群組*', '成員*'); Rows = @(@('FIN-FS-RW', 'carol'), @('FIN-FS-RW', 'PC01')) }
                @{ Name = '移除成員'; Header = @('群組*', '成員*'); Rows = @(, @('Old-Project-Team', 'dave')) }
                @{ Name = '說明'; Header = @('項目', '說明'); Rows = @(, @('x', 'y')) }
            )
            InModuleScope ADManagement -Parameters @{ P = $tpl; Sh = $sheets } { param($P, $Sh) New-XlsxWorkbook -Path $P -Sheets $Sh }
            @(
                '6', $tpl                           # 批次匯入 → 檔案（每列都有 OU，不會詢問預設 OU）
                'Welcome#2026', 'Welcome#2026'      # 初始密碼兩次
                'R', 'A'                            # 只看錯誤與略過 → 顯示全部
                'X', 'yes'                          # 確認，但輸入小寫 → 取消
                'X', 'YES'                          # 再確認，輸入大寫 YES → 執行
                'Q'
            ) | ForEach-Object { $global:InputQueue.Enqueue($_) }
            { Start-ADManagement } | Should -Not -Throw
            $text = $global:HostOutput -join "`n"
            $global:InputQueue.Count | Should -Be 0
            $text | Should -Match '預覽，尚未修改 AD'
            $text | Should -Match '已取消，沒有修改 AD'
            $text | Should -Match '工作表「說明」不是匯入用的工作表'
            $text | Should -Match '還原清單：'
            # 新增群組 1、新增使用者 1、加入成員（群組的 alice;bob + 使用者加入群組 + 群組成員 2）、移除成員（群組不存在 → 錯誤，不執行）
            $cmds = @($global:Changes | ForEach-Object Cmd)
            ($cmds | Where-Object { $_ -eq 'New-ADGroup' }).Count | Should -Be 1
            ($cmds | Where-Object { $_ -eq 'New-ADUser' }).Count | Should -Be 1
            ($cmds | Where-Object { $_ -eq 'Add-ADGroupMember' }).Count | Should -Be 5
            ($cmds | Where-Object { $_ -eq 'Remove-ADGroupMember' }).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath (Join-Path $TestDrive 'out') -Filter '還原清單_*.csv').Count | Should -Be 1
        }


        It '選擇檔案：直接按 Enter 開啟選擇檔案視窗；取消時返回；輸入 B 返回' {
            $csv = Join-Path $TestDrive 'pick.csv'
            [System.IO.File]::WriteAllText($csv, "群組,成員`r`nFinance-RW,dave`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $global:DialogResult = $csv
            Mock -ModuleName ADManagement Show-OpenFileDialog { $global:DialogCalls++; $global:DialogResult }
            $global:DialogCalls = 0
            @(
                '6', '', '3', 'B'        # Enter → 選擇檔案視窗選到 CSV → 加入成員 → 預覽後取消
                '6', 'B'                 # 輸入 B 直接返回
                'Q'
            ) | ForEach-Object { $global:InputQueue.Enqueue($_) }
            Start-ADManagement
            $global:DialogCalls | Should -Be 1
            $text = $global:HostOutput -join "`n"
            $text | Should -Match ([regex]::Escape("已選擇：$csv"))
            $text | Should -Match '加入成員'
            $global:InputQueue.Count | Should -Be 0
            # 在選擇檔案視窗按「取消」
            $global:DialogResult = $null
            @('6', '', 'Q') | ForEach-Object { $global:InputQueue.Enqueue($_) }
            Start-ADManagement
            ($global:HostOutput -join "`n") | Should -Match '沒有選擇檔案'
            $global:Changes.Count | Should -Be 0
        }

        It '以系統管理員身分執行時，提示不能拖曳並說明替代方式' {
            Mock -ModuleName ADManagement Test-RunningAsAdmin { $true }
            Mock -ModuleName ADManagement Show-OpenFileDialog { $null }
            @('6', '', 'Q') | ForEach-Object { $global:InputQueue.Enqueue($_) }
            Start-ADManagement
            $text = $global:HostOutput -join "`n"
            $text | Should -Match 'Windows 不允許從檔案總管把檔案拖進這個視窗'
            $text | Should -Match 'Shift \+ 右鍵'
        }

        It '貼上的路徑前後有引號也可以' {
            $csv = Join-Path $TestDrive 'q.csv'
            [System.IO.File]::WriteAllText($csv, "群組,成員`r`nFinance-RW,dave`r`n", (New-Object System.Text.UTF8Encoding($true)))
            @('6', "`"$csv`"", '3', 'B', 'Q') | ForEach-Object { $global:InputQueue.Enqueue($_) }
            Start-ADManagement
            ($global:HostOutput -join "`n") | Should -Match '工作表「CSV」：1 列（加入成員）'
        }

        It '選擇檔案視窗無法開啟時（例如沒有圖形介面）會提示改輸入路徑，不會中斷' {
            $r = InModuleScope ADManagement { Show-OpenFileDialog }
            if ($IsWindows) { Set-ItResult -Skipped -Because '在 Windows 上會真的開啟視窗' }
            $r | Should -BeNullOrEmpty
            ($global:HostOutput -join "`n") | Should -Match '無法開啟選擇檔案視窗'
        }

        It '單筆新增群組：取消時不做任何變更' {
            @('1', 'Test-G', '', 'OU=Groups,DC=corp,DC=local', '2', '1', '描述', '', 'alice', '', 'B', 'Q') | ForEach-Object { $global:InputQueue.Enqueue($_) }
            Start-ADManagement
            $global:InputQueue.Count | Should -Be 0
            $global:Changes.Count | Should -Be 0
            ($global:HostOutput -join "`n") | Should -Match '新增群組.*Test-G'
        }

        It '從群組移除成員：可用編號挑選' {
            @('4', 'Finance-RO', '1', 'X', 'YES', 'Q') | ForEach-Object { $global:InputQueue.Enqueue($_) }
            Start-ADManagement
            $global:InputQueue.Count | Should -Be 0
            $global:Changes.Cmd | Should -Be @('Remove-ADGroupMember')
            $global:Changes[0].Member | Should -Be 'CN=Dave Wu,OU=Users,DC=corp,DC=local'
        }

        It '最上層選單可以切換查詢與管理' {
            @('1', 'Q', '2', 'Q', 'Q') | ForEach-Object { $global:InputQueue.Enqueue($_) }
            Start-ADTool
            $global:InputQueue.Count | Should -Be 0
            $text = $global:HostOutput -join "`n"
            $text | Should -Match 'AD 權限查詢與管理工具'
            $text | Should -Match '查詢（唯讀）'
            $text | Should -Match '\[Q\] 返回上一層'
            $text | Should -Match '管理（會修改 AD'
        }
    }
}
