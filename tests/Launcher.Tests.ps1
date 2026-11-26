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
        @{ Variant = '模組檔為 UTF-16LE 有 BOM（5.1 的 > / Out-File、記事本「Unicode」）' ; Kind = 'utf16le' }
        @{ Variant = '模組檔為 UTF-16LE 無 BOM'                  ; Kind = 'utf16le-nobom' }
        @{ Variant = '模組檔為 UTF-16BE 有 BOM'                  ; Kind = 'utf16be' }
        @{ Variant = '兩個檔案都是 UTF-16LE'                     ; Kind = 'utf16le-both' }
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
            'utf16le'       { $modBytes = [byte[]](0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes([System.Text.Encoding]::UTF8.GetString($modNoBom)) }
            'utf16le-nobom' { $modBytes = [System.Text.Encoding]::Unicode.GetBytes([System.Text.Encoding]::UTF8.GetString($modNoBom)) }
            'utf16be'       { $modBytes = [byte[]](0xFE, 0xFF) + [System.Text.Encoding]::BigEndianUnicode.GetBytes([System.Text.Encoding]::UTF8.GetString($modNoBom)) }
            'utf16le-both'  {
                $modBytes = [byte[]](0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes([System.Text.Encoding]::UTF8.GetString($modNoBom))
                $startBytes = [byte[]](0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes([System.Text.Encoding]::ASCII.GetString($startBytes))
            }
            'damaged'   {
                # 用錯誤編碼讀取後又存回去（例如 Big5 讀 UTF-8 檔再存成 UTF-8），內容已無法還原
                [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
                $t = [System.Text.Encoding]::GetEncoding(950).GetString($modNoBom)
                $modBytes = $Bom + [System.Text.Encoding]::UTF8.GetBytes($t)
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
        param([string]$Dir, [string]$Culture = 'zh-TW')
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
        $r.Text | Should -Match 'AD 權限查詢工具（唯讀，不會修改 AD）'
        $r.Text | Should -Match '找不到 ActiveDirectory 模組'
        $r.Text | Should -Not -Match 'broken characters'
        $r.ExitCode | Should -Be 0
    }
}

Describe '啟動腳本：模組檔被存成 Big5（記事本選 ANSI）' {
    It '在繁體中文 Windows 上改用 ANSI 編碼讀取' {
        $dir = New-LauncherCopy -Kind 'big5'
        $r = Invoke-Launcher -Dir $dir -Culture 'zh-TW'
        $r.Text | Should -Match 'AD 權限查詢工具（唯讀，不會修改 AD）'
        $r.Text | Should -Match '找不到 ActiveDirectory 模組'
    }
}

Describe '啟動腳本：模組檔已損壞' {
    It '只顯示一則清楚的說明，不會噴出大量剖析錯誤' {
        $dir = New-LauncherCopy -Kind 'damaged'
        $r = Invoke-Launcher -Dir $dir
        $r.Text | Should -Match 'could not be read correctly'
        $r.Text | Should -Match 'download it again'
        $r.Text | Should -Not -Match 'Set-ADPermissionQueryOption'
        $r.Text | Should -Not -Match 'Not all parse errors were reported'
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
