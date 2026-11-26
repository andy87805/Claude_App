#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# 啟動腳本測試：檔案用各種方式下載 / 存檔後（有無 BOM、BOM 重複、ANSI），都要能正常啟動。
# 在獨立的 PowerShell 程序中執行，該程序沒有 ActiveDirectory 模組，所以會顯示 RSAT 說明後結束，
# 不會連線到任何 AD。

BeforeDiscovery {
    $script:Variants = @(
        @{ Variant = '原始檔'                                    ; Kind = 'original' }
        @{ Variant = '模組檔無 BOM'                              ; Kind = 'nobom' }
        @{ Variant = '複製貼上後用記事本存檔（模組檔 BOM 重複）'  ; Kind = 'doublebom' }
        @{ Variant = '模組檔開頭 BOM 變成亂碼文字'               ; Kind = 'mojibake' }
        @{ Variant = 'Windows 換行 (CRLF)'                       ; Kind = 'crlf' }
    )
}

BeforeAll {
    $script:Root = Join-Path $PSScriptRoot '..'
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Bom = [byte[]](0xEF, 0xBB, 0xBF)

    function New-LauncherCopy {
        param([string]$Kind, [scriptblock]$ModuleBytes)
        $dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        $startBytes = [System.IO.File]::ReadAllBytes((Join-Path $Root 'Start-ADPermissionQuery.ps1'))
        $modBytes = [System.IO.File]::ReadAllBytes((Join-Path $Root 'ADPermissionQuery.psm1'))
        $modNoBom = $modBytes[3..($modBytes.Length - 1)]
        switch ($Kind) {
            'original'  { }
            'nobom'     { $modBytes = $modNoBom }
            # 從 GitHub 網頁複製貼上、再用記事本存成「UTF-8 with BOM」：
            # 模組檔原本就有 BOM → 變成兩個；啟動腳本是純 ASCII，原本沒有 BOM → 只會有一個
            'doublebom' { $modBytes = $Bom + $modBytes; $startBytes = $Bom + $startBytes }
            'mojibake'  {
                $prefix = [System.Text.Encoding]::UTF8.GetBytes([string]::new([char[]](0xEF, 0xBB, 0xBF)))
                $modBytes = $Bom + $prefix + $modNoBom
                $startBytes = $Bom + $startBytes
            }
            'crlf'      {
                $t = [System.Text.Encoding]::UTF8.GetString($modNoBom) -replace "`r?`n", "`r`n"
                $modBytes = $Bom + [System.Text.Encoding]::UTF8.GetBytes($t)
                $s = [System.Text.Encoding]::ASCII.GetString($startBytes) -replace "`r?`n", "`r`n"
                $startBytes = [System.Text.Encoding]::ASCII.GetBytes($s)
            }
            'big5'      {
                [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
                $t = [System.Text.Encoding]::UTF8.GetString($modNoBom)
                $modBytes = [System.Text.Encoding]::GetEncoding(950).GetBytes($t)
            }
        }
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'Start-ADPermissionQuery.ps1'), [byte[]]$startBytes)
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'ADPermissionQuery.psm1'), [byte[]]$modBytes)
        return $dir
    }

    function Invoke-Launcher {
        param([string]$Dir, [string]$Culture = '')
        $script = Join-Path $Dir 'Start-ADPermissionQuery.ps1'
        $cmd = "& '$script' -NoLog"
        if ($Culture) { $cmd = "[System.Globalization.CultureInfo]::CurrentCulture = '$Culture'; $cmd" }
        $out = & $Pwsh -NoLogo -NoProfile -NonInteractive -Command $cmd 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($out | Out-String) }
    }
}

Describe '啟動腳本：<Variant>' -ForEach $Variants {
    It '可以正常載入模組並顯示中文' {
        $dir = New-LauncherCopy -Kind $Kind
        $r = Invoke-Launcher -Dir $dir
        $r.Text | Should -Not -Match 'ParserError|UnexpectedAttribute|未預期|Unexpected'
        $r.Text | Should -Match '資料夾權限查詢工具（唯讀，不會修改 AD）'
        $r.Text | Should -Match '找不到 ActiveDirectory 模組'
        $r.Text | Should -Not -Match 'broken characters'
        $r.ExitCode | Should -Be 0
    }
}

Describe '啟動腳本：模組檔被存成 Big5（記事本選 ANSI）' {
    It '在繁體中文 Windows 上改用 ANSI 編碼讀取' {
        $dir = New-LauncherCopy -Kind 'big5'
        $r = Invoke-Launcher -Dir $dir -Culture 'zh-TW'
        $r.Text | Should -Match '資料夾權限查詢工具（唯讀，不會修改 AD）'
        $r.Text | Should -Match '找不到 ActiveDirectory 模組'
    }
}

Describe '啟動腳本：缺少模組檔' {
    It '顯示清楚的錯誤訊息' {
        $dir = New-LauncherCopy -Kind 'original'
        Remove-Item -LiteralPath (Join-Path $dir 'ADPermissionQuery.psm1')
        $r = Invoke-Launcher -Dir $dir
        $r.Text | Should -Match 'Cannot find ADPermissionQuery\.psm1'
    }
}
