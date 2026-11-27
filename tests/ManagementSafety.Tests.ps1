#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# 管理模組安全檢查：靜態分析程式碼，確保「會修改 AD」的部分被限制在最小範圍。

BeforeAll {
    $file = Join-Path $PSScriptRoot '..' 'ADManagement.psm1'
    $script:Bytes = [System.IO.File]::ReadAllBytes($file)
    $tokens = $null; $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    $script:ParseErrors = $errors
    $script:Commands = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))

    function Get-ParentFunctionName {
        param($Node)
        $p = $Node.Parent
        while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }
        if ($p) { return $p.Name }
        return $null
    }

    # 允許的「修改 AD」指令（還原用的刪除只針對還原清單中記錄的 ObjectGUID）
    $script:AllowedChange = @('New-ADGroup', 'New-ADUser', 'Add-ADGroupMember', 'Remove-ADGroupMember', 'Move-ADObject', 'Remove-ADUser', 'Remove-ADGroup')
    $script:ChangeCommands = @($Commands | Where-Object {
            $n = $_.GetCommandName()
            $n -and $n -match '^(New|Add|Remove|Set|Move|Rename|Enable|Disable|Unlock|Clear|Reset|Restore|Grant|Revoke|Install|Uninstall)-AD'
        })
}

Describe '管理模組安全檢查' {
    It '語法正確' {
        $ParseErrors | Should -BeNullOrEmpty
    }

    It '只使用允許的修改指令（不會改密碼、改名、停用帳號、修改屬性、刪除其他物件）' {
        $names = @($ChangeCommands | ForEach-Object { $_.GetCommandName() } | Sort-Object -Unique)
        @($names | Where-Object { $_ -notin $AllowedChange }) | Should -BeNullOrEmpty
        $all = @($Commands | ForEach-Object { $_.GetCommandName() })
        foreach ($bad in 'Set-Acl', 'Remove-ADObject', 'Set-ADAccountPassword', 'Set-ADUser', 'Set-ADGroup', 'Set-ADObject', 'Rename-ADObject', 'Disable-ADAccount', 'Invoke-Expression', 'Start-Process', 'Invoke-Command', 'Remove-Item') {
            $all | Should -Not -Contain $bad
        }
    }

    It '修改 AD 的指令只出現在 Invoke-ADChangeItem 一個函式中' {
        $ChangeCommands.Count | Should -BeGreaterThan 0
        foreach ($c in $ChangeCommands) {
            Get-ParentFunctionName $c | Should -Be 'Invoke-ADChangeItem' -Because "$($c.GetCommandName()) 出現在第 $($c.Extent.StartLineNumber) 行"
        }
    }

    It 'Invoke-ADChangeItem 只由 Invoke-ADChangePlan 呼叫' {
        $calls = @($Commands | Where-Object { $_.GetCommandName() -eq 'Invoke-ADChangeItem' })
        $calls.Count | Should -Be 1
        Get-ParentFunctionName $calls[0] | Should -Be 'Invoke-ADChangePlan'
    }

    It 'Invoke-ADChangePlan 只在使用者輸入大寫 YES 之後才呼叫' {
        $calls = @($Commands | Where-Object { $_.GetCommandName() -eq 'Invoke-ADChangePlan' })
        $calls.Count | Should -Be 1
        Get-ParentFunctionName $calls[0] | Should -Be 'Invoke-PlanReview'
        # 往上找 if 判斷式，條件必須是「-ceq 'YES'」（區分大小寫）
        $p = $calls[0].Parent; $guard = $null
        while ($p -and -not $guard) {
            if ($p -is [System.Management.Automation.Language.IfStatementAst]) { $guard = $p }
            $p = $p.Parent
        }
        $guard | Should -Not -BeNullOrEmpty
        $guard.Clauses[0].Item1.Extent.Text | Should -Match "-ceq 'YES'"
    }

    It '執行函式不會被匯出（只能透過預覽畫面確認後執行）' {
        $exports = @($Commands | Where-Object { $_.GetCommandName() -eq 'Export-ModuleMember' })
        $exports.Count | Should -Be 1
        $text = $exports[0].Extent.Text
        $text | Should -Not -Match 'Invoke-ADChangePlan'
        $text | Should -Not -Match 'Invoke-ADChangeItem'
    }

    It '查詢模組（ADPermissionQuery.psm1）仍然沒有任何修改 AD 的指令' {
        $q = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..' 'ADPermissionQuery.psm1'), [ref]$null, [ref]$null)
        $names = @($q.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        @($names | Where-Object { $_ -match '^(New|Add|Remove|Set|Move|Rename|Enable|Disable|Unlock)-AD' }) | Should -BeNullOrEmpty
    }

    It '檔案為 UTF-8 with BOM' {
        $Bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }
}
