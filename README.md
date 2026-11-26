# 資料夾權限查詢工具（AD 環境用 PowerShell）

輸入一個資料夾或共用路徑，查出**哪些人員、群組有權限**，再選一個群組，列出**群組內的人員與資訊**（姓名、帳號、部門、職稱、Email、帳號狀態…）。

> 🛡 **全程唯讀，不會修改 AD 或權限**
> - 只用 `Get-Acl`、`Get-ChildItem`、`Get-ADObject`、`Get-ADUser`、`Get-ADGroup`、`Get-ADGroupMember` 這類查詢指令。
> - 程式裡沒有任何 `Set-*`、`Add-AD*`、`Remove-*`、`Set-Acl` 等異動指令；`tests\ReadOnly.Tests.ps1` 會自動掃描程式碼確認這一點。
> - 只會在**你自己的電腦上**寫兩種檔案：查詢紀錄 log，以及你主動匯出的 CSV / HTML 報表。

---

## 功能

| 功能 | 說明 |
| --- | --- |
| 查詢路徑權限 | 列出帳戶、顯示名稱、類型（群組 / 使用者 / 內建帳戶…）、權限（完全控制、修改、讀取和執行…）、允許/拒絕、套用到、是否繼承；同時顯示擁有者與是否中斷繼承 |
| 選擇群組看成員 | 用視窗（Out-GridView，可排序、搜尋）或編號挑選群組 |
| 巢狀群組展開 | 群組裡還有群組時遞迴展開，「取得途徑」欄會標示例如 `Finance-RW > Finance-Managers`；遇到循環群組不會卡住 |
| 帳號狀態 | 標示 **停用、鎖定、密碼已過期、超過 N 天未登入、從未登入**，可一鍵只看異常帳號 |
| 反查使用者 | 輸入帳號，列出他在這個路徑透過哪個群組取得什麼權限；有「拒絕」權限也會提醒 |
| 子資料夾掃描 | 往下掃描 N 層，只列出**中斷繼承**或**有額外明確權限**的子資料夾 |
| 關鍵字篩選 | 成員清單可用姓名、帳號、部門等關鍵字篩選，多個關鍵字用空白分隔 |
| 匯出報表 | CSV（含 BOM，Excel 直接開不會亂碼）與 HTML 報表 |
| 查詢紀錄 | 每次查詢記錄時間、操作者、電腦、動作、目標到本機 log |
| 異常提醒 | 孤立 SID（帳戶已刪除但權限還在）、拒絕權限 |

---

## 需求

- Windows 10 / 11 或 Windows Server，**Windows PowerShell 5.1** 或 **PowerShell 7**
- 已加入網域的電腦，用網域帳號登入（一般網域使用者通常就有讀取 AD 的權限）
- **RSAT：Active Directory 模組**
  - Windows 10/11：設定 → 應用程式 → 選用功能 → 新增「RSAT: Active Directory Domain Services and Lightweight Directory Services Tools」
  - Windows Server：`Install-WindowsFeature RSAT-AD-PowerShell`
- 對要查詢的資料夾有「讀取權限」的權限（查看安全性頁籤所需的權限）

## 使用方式

1. 下載這個分支的檔案，把 `ADPermissionQuery.psm1` 和 `Start-ADPermissionQuery.ps1` 放在同一個資料夾。
   建議在 GitHub 分支頁面按「Code → Download ZIP」解壓縮，或開啟檔案後按右上角的下載按鈕（Download raw file）。
   用複製貼上存檔也可以，啟動腳本會自動處理編碼。
2. 開啟 PowerShell，切到該資料夾並執行：

   ```powershell
   # 若出現「無法載入，因為這個系統上已停用指令碼執行」，先執行這行（只對目前視窗有效）
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

   .\Start-ADPermissionQuery.ps1
   ```

3. 依照畫面操作：

   ```
   請輸入資料夾路徑（例如 \\fileserver\share\財務部），輸入 Q 離開: \\fs01\share\Finance

   擁有者：CORP\FileAdmin　繼承：有繼承上層
   === 權限清單：\\fs01\share\Finance ===
   #  帳戶              顯示名稱  類型     權限        允許/拒絕  套用到                  繼承
   1  BUILTIN\Admini... ...       內建/特殊帳戶  完全控制  允許   此資料夾、子資料夾及檔案   是
   4  CORP\Finance-RW             群組     修改        允許       此資料夾、子資料夾及檔案   否
   ...

   [1] 選擇群組查看成員  [2] 反查使用者權限  [3] 掃描子資料夾  [4] 匯出權限清單  [5] 重新顯示  [N] 查詢其他路徑  [Q] 離開
   ```

   進入群組成員後：

   ```
   [F] 關鍵字篩選  [A] 只看狀態異常帳號  [C] 清除篩選  [E] 匯出目前清單  [S] 重新顯示  [B] 返回
   ```

### 參數

| 參數 | 說明 |
| --- | --- |
| `-Path` | 直接指定要查詢的路徑 |
| `-Server` | 指定網域控制站或網域，例如 `dc01.corp.local`（查其他網域時用） |
| `-InactiveDays` | 超過幾天未登入算「久未登入」，預設 90 |
| `-LogPath` | 查詢紀錄位置，預設 `%LOCALAPPDATA%\ADPermissionQuery\query.log` |
| `-NoLog` | 不寫查詢紀錄 |
| `-NoGui` | 不開 Out-GridView 視窗，全部用文字選單（Server Core、遠端工作階段適用） |

```powershell
.\Start-ADPermissionQuery.ps1 -Path '\\fs01\share\財務部' -InactiveDays 60
.\Start-ADPermissionQuery.ps1 -Server dc01.corp.local -NoGui
```

### 在其他腳本裡使用（進階）

```powershell
Import-Module .\ADPermissionQuery.psm1
$r = Get-PathPermission -Path '\\fs01\share\Finance'
$r.Permissions | Format-Table Identity, Category, Rights, AccessType
Get-GroupMemberDetail -Identity 'Finance-RW' -Recurse | Export-Csv members.csv -NoTypeInformation -Encoding UTF8
Find-UserPathAccess -Path '\\fs01\share\Finance' -User 'jdoe'
Get-SubfolderPermissionDiff -Path '\\fs01\share\Finance' -Depth 3
```

報表預設存到「文件\ADPermissionReports」。

---

## 注意事項與限制

- **只查 NTFS 權限**，不含「共用權限（Share Permission）」。實際有效權限是 NTFS 與共用權限兩者中較嚴格的。
- **本機群組**（例如檔案伺服器上的 `BUILTIN\Administrators`、`BUILTIN\Users`）不是 AD 物件，成員要在該伺服器上查看；反查使用者時會標示「需確認」。
- 反查使用者用的是 AD 的 `tokenGroups`（包含巢狀與主要群組），不包含 SID History。
- 若群組超過 5,000 名成員，`Get-ADGroupMember` 可能失敗，工具會自動改用 member 屬性讀取（這種方式不含「主要群組」為該群組的成員，畫面會有提示）。
- 「最後登入」使用 `LastLogonDate`（lastLogonTimestamp），在網域控制站間同步會有最多約 14 天誤差。
- 成員很多的群組逐一讀取使用者資料會花一點時間。

---

## 疑難排解

| 狀況 | 處理方式 |
| --- | --- |
| `未預期的屬性 'CmdletBinding'`、`運算式或陳述式中有未預期的 'param' 語彙基元` | 舊版啟動腳本在檔案開頭多了看不見的 BOM 字元（常見於從網頁複製貼上後存檔）。請重新下載最新的 `Start-ADPermissionQuery.ps1`；新版是純英文 ASCII 檔，不會再發生 |
| `以 "1" 引數呼叫 "Create" 時發生例外狀況`，後面接一堆亂碼與剖析錯誤 | 舊版啟動腳本無法讀取存成 UTF-16（Unicode）的模組檔（例如用 Windows PowerShell 的 `>`、`Out-File` 或記事本「Unicode」存檔）。請重新下載最新的 `Start-ADPermissionQuery.ps1`，新版會自動判斷 UTF-8 / UTF-16 / ANSI |
| `ADPermissionQuery.psm1 could not be read correctly` | 模組檔內容已損壞（通常是用錯誤的編碼開啟後又存檔），請重新下載 `ADPermissionQuery.psm1`，不要轉檔或另存 |
| 「因為這個系統上已停用指令碼執行，所以無法載入」 | 先執行 `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`（只對目前視窗有效） |
| 「找不到 ActiveDirectory 模組」 | 安裝 RSAT 的 Active Directory 模組（見上方「需求」） |
| 中文顯示成亂碼 | 重新下載 `ADPermissionQuery.psm1`；若用記事本存檔，請選「UTF-8」編碼 |

## 測試

測試使用 [Pester 5](https://pester.dev)，**全部使用假的 AD 與 ACL 資料（Mock），不會連到任何 AD**，可以在任何電腦上執行：

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser   # 第一次才需要
Invoke-Pester -Path .\tests -Output Detailed
```

- `tests\ADPermissionQuery.Tests.ps1`：各項功能與完整互動流程（模擬使用者輸入）
- `tests\ReadOnly.Tests.ps1`：靜態掃描程式碼，確認只用查詢類指令、不呼叫修改 ACL / AD 的方法、寫檔只限 log 與報表
- `tests\Launcher.Tests.ps1`：模擬各種下載 / 存檔方式（有無 BOM、BOM 重複、CRLF、UTF-16LE/BE、Big5、已損壞），確認啟動腳本都能正常載入或清楚說明
