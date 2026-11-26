#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# 唯讀安全檢查：靜態分析程式碼，確保工具「不可能」修改 AD 或 NTFS 權限。

BeforeDiscovery {
    $script:Files = @(
        Join-Path $PSScriptRoot '..' 'ADPermissionQuery.psm1'
        Join-Path $PSScriptRoot '..' 'Start-ADPermissionQuery.ps1'
    ) | ForEach-Object { @{ File = (Resolve-Path $_).Path; Name = (Split-Path $_ -Leaf) } }
}

Describe '唯讀檢查：<Name>' -ForEach $Files {
    BeforeAll {
        $tokens = $null; $errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errors)
        $script:ParseErrors = $errors
        $script:Commands = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $script:CommandNames = @($Commands | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        # 本工具自己定義的函式（一律以模組檔為準，啟動腳本會呼叫它們）
        $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..' 'ADPermissionQuery.psm1'), [ref]$null, [ref]$null)
        $script:Functions = @(@($moduleAst, $Ast) | ForEach-Object {
                $_.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
            } | ForEach-Object Name | Sort-Object -Unique)

        # 允許使用的指令清單：全部都是「查詢 / 顯示 / 本機檔案輸出」類
        $script:Allowed = @(
            # AD：只允許 Get
            'Get-ADObject', 'Get-ADUser', 'Get-ADGroup', 'Get-ADGroupMember', 'Get-ADComputer'
            # 檔案系統：只讀
            'Get-Acl', 'Get-ChildItem', 'Test-Path', 'Join-Path', 'Split-Path', 'Resolve-Path', 'Get-Location'
            # 本機輸出（log 與報表）
            'New-Item', 'Add-Content', 'Export-Csv', 'Out-File', 'ConvertTo-Html'
            # 一般
            'Get-Command', 'Get-Module', 'Import-Module', 'New-Module', 'Export-ModuleMember', 'Get-Date', 'New-Object',
            'Select-Object', 'Where-Object', 'ForEach-Object', 'Sort-Object', 'Format-Table', 'Out-String', 'Out-Null',
            'Out-GridView', 'Write-Host', 'Write-Warning', 'Write-Verbose', 'Write-Error', 'Write-Progress', 'Read-Host'
        )
    }

    It '語法正確' {
        $ParseErrors | Should -BeNullOrEmpty
    }

    It '只使用允許清單中的指令（或本工具自己的函式）' {
        $unexpected = @($CommandNames | Where-Object { $_ -notin $Allowed -and $_ -notin $Functions })
        $unexpected | Should -BeNullOrEmpty -Because '新增任何指令都必須先確認不會異動 AD / 權限'
    }

    It 'AD 相關指令只能是 Get-*' {
        $ad = @($CommandNames | Where-Object { $_ -match '-AD' -and $_ -notmatch '^Get-AD' -and $_ -notin $Functions })
        $ad | Should -BeNullOrEmpty
    }

    It '不使用任何會異動的指令' {
        $bad = @($CommandNames | Where-Object {
                $_ -match '^(Set|Add|Remove|New|Clear|Move|Rename|Enable|Disable|Unlock|Grant|Revoke|Reset|Restore|Install|Uninstall)-' -and
                $_ -notin @('New-Item', 'Add-Content', 'New-Object', 'New-Module') -and $_ -notin $Functions
            })
        $bad | Should -BeNullOrEmpty
        $CommandNames | Should -Not -Contain 'Set-Acl'
        $CommandNames | Should -Not -Contain 'Invoke-Expression'
        $CommandNames | Should -Not -Contain 'Start-Process'
        $CommandNames | Should -Not -Contain 'Invoke-Command'
    }

    It '不呼叫會修改 ACL / AD 的 .NET 方法' {
        $forbidden = 'SetAccessRule', 'AddAccessRule', 'RemoveAccessRule', 'RemoveAccessRuleAll', 'RemoveAccessRuleSpecific',
        'ResetAccessRule', 'PurgeAccessRules', 'SetAccessRuleProtection', 'SetOwner', 'SetGroup', 'SetAccessControl',
        'CommitChanges', 'SetInfo', 'Put', 'PutEx', 'DeleteTree', 'Delete', 'MoveTo', 'Rename', 'Invoke', 'InvokeSet',
        'Save', 'Add', 'Remove'
        $calls = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
        $bad = @(foreach ($c in $calls) {
                $m = $c.Member.Extent.Text
                if ($m -in $forbidden) {
                    # .Add() 只允許用在本機的 List / HashSet / 字典 / StringBuilder
                    $target = $c.Expression.Extent.Text
                    if ($m -eq 'Add' -and $target -match '^\$(names|results|rows|flags|groupSids|visited|global:\w+)$') { continue }
                    "$target.$m()（第 $($c.Extent.StartLineNumber) 行）"
                }
            })
        $bad | Should -BeNullOrEmpty
    }

    It '寫入檔案的指令只出現在 log 與匯出報表函式中' {
        $writers = @($Commands | Where-Object { $_.GetCommandName() -in 'New-Item', 'Add-Content', 'Export-Csv', 'Out-File' })
        foreach ($w in $writers) {
            $p = $w.Parent
            while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }
            $p.Name | Should -BeIn @('Write-QueryLog', 'Export-QueryReport')
        }
    }

    It '檔案編碼：啟動腳本只含 ASCII；模組為 UTF-8 with BOM' {
        $bytes = [System.IO.File]::ReadAllBytes($File)
        if ($Name -eq 'Start-ADPermissionQuery.ps1') {
            # 純 ASCII：不論用什麼方式下載、存檔（有無 BOM、UTF-8 / ANSI）都能正確解析
            @($bytes | Where-Object { $_ -ge 0x80 }).Count | Should -Be 0
        }
        else {
            # BOM 讓直接 Import-Module 的 Windows PowerShell 5.1 也能正確讀中文
            $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            { $strict.GetString($bytes) } | Should -Not -Throw
        }
    }
}
