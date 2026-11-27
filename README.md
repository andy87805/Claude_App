# AD 權限查詢與管理工具（PowerShell）

啟動後先選擇 **[1] 查詢（唯讀）** 或 **[2] 管理（會修改 AD）**：

- **查詢**：輸入資料夾或共用路徑查出**哪些人員、群組有權限**、查**群組成員**、**使用者 / 電腦資訊與所屬群組**、**比較兩位使用者的群組**等。
- **管理**：新增群組 / 使用者、加入 / 移除群組成員、**搬移物件到其他 OU**，或**讀取 Excel 批次處理**，並依欄位填入描述、附註等資料。每個動作都會**先預覽（dry run）**，確認沒問題後輸入 `YES` 才執行。

| 檔案 | 用途 |
| --- | --- |
| `Start-ADPermissionQuery.ps1` | 啟動程式 |
| `ADPermissionQuery.psm1` | 查詢功能（**唯讀**） |
| `ADManagement.psm1` | 管理功能（會修改 AD）。**不放這個檔案**，或啟動時加 `-QueryOnly`，就只有查詢功能 |

> 🛡 **查詢功能全程唯讀**
> - 只用 `Get-Acl`、`Get-ChildItem`、`Get-ADObject`、`Get-ADUser`、`Get-ADGroup`、`Get-ADGroupMember`、`Get-ADComputer` 這類查詢指令。
> - 查詢模組裡沒有任何 `Set-*`、`Add-AD*`、`Remove-*`、`Set-Acl` 等異動指令；`tests\ReadOnly.Tests.ps1` 會自動掃描程式碼確認這一點。
> - 只會在**你自己的電腦上**寫兩種檔案：查詢紀錄 log，以及你主動匯出的 CSV / HTML 報表。

> ⚠️ **管理功能的安全機制**
> - 一律**先預覽**：每一筆會「將執行 / 略過 / 錯誤」以及原因都列出來，預覽時只會查詢 AD，不會修改。
> - 要輸入**大寫 `YES`** 才會執行；輸入其他內容（包括小寫 yes）都會取消。
> - 會修改 AD 的指令**只集中在一個函式**，而且只有 `New-ADGroup`、`New-ADUser`、`Add-ADGroupMember`、`Remove-ADGroupMember`、`Move-ADObject`（以及還原時的 `Remove-ADUser`、`Remove-ADGroup`）；不會改密碼、改名、停用帳號或修改既有物件的屬性。`tests\ManagementSafety.Tests.ps1` 會掃描程式碼確認這些規則。
> - 執行後自動產生**執行結果報表**與**還原清單**，需要時可以一鍵復原（一樣先預覽）。

---

## 查詢功能

| 選項 | 說明 |
| --- | --- |
| [1] 查詢路徑權限 | 誰有這個資料夾的權限；可再選群組看成員、反查使用者、掃描子資料夾 |
| [2] 查群組成員 | 輸入群組名稱（可只打一部分，找到多個時從清單挑），列出成員 |
| [3] 查使用者資訊與所屬群組 | 輸入帳號或姓名，顯示個人資料（部門、職稱、主管、帳號狀態、密碼、最後登入、所在 OU…）與所屬的所有群組，並標示是「直接」加入還是「透過」哪個群組 |
| [4] 比較兩位使用者的群組 | 列出只有 A 有、只有 B 有、兩人都有的群組（含巢狀），常用於「新人權限比照某位同事」 |
| [5] 搜尋帳號 | 用帳號、姓名、部門、職稱、Email、員工編號找人，可再點進去看詳細資料 |
| [6] 反查使用者在某個路徑的權限 | 直接輸入帳號＋路徑，不用先查路徑 |
| [7] 查電腦帳號 | 作業系統、IP、狀態（停用 / 久未登入）、最後登入、所在 OU、所屬群組 |
| [8] 查群組被用在哪些資料夾 | 從指定資料夾往下掃描，找出有給這個群組權限的資料夾（預設只列明確設定的，可選擇連繼承的一起列） |

輸入名稱時都可以只打一部分，例如輸入 `財務` 會列出名稱含「財務」的群組或部門是財務部的人。

## 功能細節

| 功能 | 說明 |
| --- | --- |
| 查詢路徑權限 | 列出帳戶、顯示名稱、類型（群組 / 使用者 / 內建帳戶…）、權限（完全控制、修改、讀取和執行…）、允許/拒絕、套用到、是否繼承；同時顯示擁有者與是否中斷繼承 |
| 選擇群組看成員 | 用視窗（Out-GridView，可排序、搜尋）或編號挑選群組 |
| 巢狀群組展開 | 群組裡還有群組時遞迴展開，「取得途徑」欄會標示例如 `Finance-RW > Finance-Managers`；遇到循環群組不會卡住 |
| 帳號狀態 | 標示 **停用、鎖定、密碼已過期、超過 N 天未登入、從未登入**，可一鍵只看異常帳號 |
| 反查使用者 | 輸入帳號，列出他在這個路徑透過哪個群組取得什麼權限；有「拒絕」權限也會提醒 |
| 子資料夾掃描 | 往下掃描 N 層，只列出**中斷繼承**或**有額外明確權限**的子資料夾 |
| 關鍵字篩選 | 所有清單（成員、群組、搜尋結果、比較結果…）都可用關鍵字篩選，多個關鍵字用空白分隔 |
| 匯出報表 | CSV（含 BOM，Excel 直接開不會亂碼）與 HTML 報表 |
| 查詢紀錄 | 每次查詢記錄時間、操作者、電腦、動作、目標到本機 log |
| 異常提醒 | 孤立 SID（帳戶已刪除但權限還在）、拒絕權限 |

---

## 管理功能

| 選項 | 說明 |
| --- | --- |
| [1] 新增群組 | 單筆輸入：名稱、帳號、OU、範圍、類型、描述、附註、要加入的成員 |
| [2] 新增使用者 | 單筆輸入：帳號、姓名、OU、Email、部門、職稱、電話、主管、描述、附註、到期日、要加入的群組 |
| [3] 加入成員到群組 | 一次可加多個（使用者、群組或電腦） |
| [4] 從群組移除成員 | 列出目前成員，用編號或帳號挑選 |
| [5] 搬移物件到其他 OU | 使用者、群組、電腦；會先查出目前所在的 OU，一次可輸入多個 |
| [6] 從 Excel 批次匯入 | 讀取 `.xlsx` 或 `.csv`：建立群組、建立使用者、加入成員、移除成員、搬移物件 |
| [7] 產生 Excel 範本 | 產生含「群組」「使用者」「群組成員」「移除成員」「搬移」「說明」工作表的範本 |
| [8] 用還原清單復原 | 載入執行後產生的還原清單，復原那次的變更 |

### Excel 格式

不需要安裝 Excel 或其他模組就能讀取。工作表名稱決定資料種類，第 1 列是標題（中文或英文都可以，標題後面的 `*` 會被忽略）：

| 工作表 | 欄位（* 為必填） |
| --- | --- |
| 群組 | 群組名稱\*、帳號、OU\*、範圍（全域 / 網域本機 / 萬用）、類型（安全性 / 發佈）、顯示名稱、**描述**、**附註**、成員、加入到群組 |
| 使用者 | 帳號\*、姓、名、顯示名稱、OU\*、UPN、Email、部門、職稱、公司、辦公室、電話、手機、員工編號、主管、**描述**、**附註**、帳號到期日、啟用、加入群組 |
| 群組成員 | 群組\*、成員\* |
| 移除成員 | 群組\*、成員\* |
| 搬移 | 物件\*、目前 OU、目標 OU\* |

- 「成員」「加入群組」可以填多個，用 `;` 或 `,` 分隔。
- **OU** 有兩種寫法（OU 空白時，匯入時可以指定一個預設 OU，也可以用這兩種寫法）：

  | 寫法 | 例子 |
  | --- | --- |
  | 用 `/` 分隔，**由上往下**寫（和 AD 樹狀圖相同） | `台北/財務部/帳號` |
  | 同上，開頭加網域名稱（AD「物件」頁籤顯示的格式） | `corp.local/台北/財務部/帳號` |
  | 完整的 DN，**由下往上**寫 | `OU=帳號,OU=財務部,OU=台北,DC=corp,DC=local` |

  用 `/` 的寫法時，程式會逐層找 OU（找不到再找同名的內建容器，例如 `Users`）。某一層打錯時，預覽會指出是哪一層，例如「找不到「財務部」這一層」。名稱中有逗號等特殊字元時直接照打即可，會自動處理。
- 「附註」會寫入 AD 的 `info` 屬性（「內容」視窗中「電話」頁籤的附註欄）。
- 「帳號到期日」填 `2026-12-31` 表示可以使用到當天結束。
- **初始密碼**：匯入時輸入一組共用密碼（畫面不顯示，不會存到任何檔案），使用者第一次登入時必須變更。預覽時會依網域密碼原則檢查長度與複雜度。
- **已存在的群組 / 帳號**：會略過，不會修改既有物件；但該列要加入的成員 / 群組仍會處理。

### 搬移物件

- 「物件」可以填帳號、電腦名稱（不用加 `$`）、名稱或 DN。
- 「目前 OU」可以空白。程式一律會查出物件**實際所在的 OU**，預覽顯示「從 X → 到 Y」。
- 有填「目前 OU」但物件**不在那裡**時，預覽標示為「**需確認**」並說明實際位置，接著詢問你：
  - `[Y]` 全部照實際位置搬移　`[N]` 全部不搬　`[O]` 逐筆確認（每一筆問「目前在 X，要搬到 Y 嗎？」）
- 已經在目標 OU 的會略過；找不到物件、同名物件不只一個（會列出各自的位置）、目標 OU 不存在或已有同名物件、物件開啟了「防止意外刪除」都會標示錯誤。
- 同一次匯入中，搬移排在最後執行；還原清單會記錄原本的 OU，可以搬回去。

### 預覽會檢查的項目

OU 是否存在、帳號格式（長度、不允許的字元）、帳號 / UPN 是否已被使用、同一個 OU 內是否有同名物件、Excel 內是否重複、主管是否存在、到期日與欄位值格式、初始密碼是否符合網域原則、成員與群組是否存在、是否已經是成員 / 不是成員。

### 還原清單

每次執行後會在「文件\ADPermissionReports」產生 `還原清單_日期時間.csv`，記錄這次新增了哪些物件（含 ObjectGUID）、加入 / 移除了哪些成員、搬移了哪些物件。用管理選單 [8] 載入後會先預覽：

- 新增的群組 / 使用者 → 刪除（**只刪除 ObjectGUID 相符的物件**，不會刪到之後建立的同名物件；已經不存在的會略過）
- 加入的成員 → 移除；移除的成員 → 加回
- 搬移的物件 → 搬回原本的 OU

> 刪除使用者無法復原（除非網域有啟用 AD 資源回收筒），預覽時會特別提醒。

## 需求

- Windows 10 / 11 或 Windows Server，**Windows PowerShell 5.1** 或 **PowerShell 7**
- 已加入網域的電腦，用網域帳號登入（一般網域使用者通常就有讀取 AD 的權限）
- **RSAT：Active Directory 模組**
  - Windows 10/11：設定 → 應用程式 → 選用功能 → 新增「RSAT: Active Directory Domain Services and Lightweight Directory Services Tools」
  - Windows Server：`Install-WindowsFeature RSAT-AD-PowerShell`
- 對要查詢的資料夾有「讀取權限」的權限（查看安全性頁籤所需的權限）
- 使用管理功能時：需要在目標 OU 建立物件、修改群組成員、搬移物件的 AD 權限

## 使用方式

### 最簡單的方式：雙擊執行

1. 在 GitHub 分支頁面按「**Code → Download ZIP**」下載。
2. 在下載的 ZIP 檔按右鍵 →「**內容**」→ 勾選下方的「**解除封鎖**」→ 確定，再解壓縮。
   （沒有解除封鎖的話，Windows 可能會在執行時跳出安全性警告，按「執行」也可以。）
3. 在解壓縮後的資料夾中，**雙擊 `AD工具.cmd`** 就會開啟。

> 💡 想放在桌面：在 `AD工具.cmd` 按右鍵 →「傳送到」→「桌面（建立捷徑）」。之後從桌面雙擊即可。
>
> `AD工具.cmd` 只對這次執行套用 `-ExecutionPolicy Bypass`，**不會更改電腦的執行原則設定**。
> 程式出錯（例如沒裝 RSAT）時視窗會停住讓你看訊息；正常離開時視窗會自動關閉。

需要的檔案（放在同一個資料夾）：`AD工具.cmd`、`Start-ADPermissionQuery.ps1`、`ADPermissionQuery.psm1`，要用管理功能時再加 `ADManagement.psm1`。`tests` 資料夾只有測試用，可以不用。

### 從 PowerShell 執行（進階）

```powershell
# 若出現「無法載入，因為這個系統上已停用指令碼執行」，先執行這行（只對目前視窗有效）
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

.\Start-ADPermissionQuery.ps1
```

### 操作畫面

依照畫面操作。啟動後先選擇功能：

   ```
    請選擇功能
    --------------------
     [1] 查詢（唯讀）        路徑權限、群組成員、使用者 / 電腦資訊、比較群組...
     [2] 管理（會修改 AD）   新增群組 / 使用者、加入 / 移除成員、Excel 批次匯入
     [Q] 離開
   ```

   選 [1] 查詢後：

   ```
    查詢（唯讀）
    --------------------
     [1] 查詢路徑權限      誰有這個資料夾的權限
     [2] 查群組成員        輸入群組名稱，列出成員
     [3] 查使用者          個人資料與所屬群組
     [4] 比較兩位使用者    群組差異（新人權限比照同事）
     [5] 搜尋帳號          用姓名、部門、職稱、Email 找人
     [6] 反查使用者權限    某人在某個路徑有什麼權限
     [7] 查電腦帳號        作業系統、IP、狀態、所屬群組
     [8] 查群組使用處      群組被用在哪些資料夾
     [Q] 返回上一層
   ```

   例如選 [1] 查詢路徑權限：

   ```
   請輸入資料夾路徑（例如 \\fileserver\share\財務部），直接按 Enter 返回: \\fs01\share\Finance

   擁有者：CORP\FileAdmin　繼承：有繼承上層
   === 權限清單：\\fs01\share\Finance ===
   #  帳戶              顯示名稱  類型     權限        允許/拒絕  套用到                  繼承
   1  BUILTIN\Admini... ...       內建/特殊帳戶  完全控制  允許   此資料夾、子資料夾及檔案   是
   4  CORP\Finance-RW             群組     修改        允許       此資料夾、子資料夾及檔案   否
   ...

   [1] 選擇群組查看成員  [2] 反查使用者權限  [3] 掃描子資料夾  [4] 匯出權限清單  [5] 重新顯示  [N] 查詢其他路徑  [B] 回主選單  [Q] 離開
   ```

   進入群組成員後：

   ```
   [A] 只看狀態異常帳號  [V] 查看某位成員的詳細資料  [F] 關鍵字篩選  [C] 清除篩選  [E] 匯出目前清單  [S] 重新顯示  [B] 返回
   ```

### 參數

| 參數 | 說明 |
| --- | --- |
| `-Path` | 啟動後直接查詢這個路徑的權限（查完回到主選單） |
| `-Server` | 指定網域控制站或網域，例如 `dc01.corp.local`（查其他網域時用） |
| `-InactiveDays` | 超過幾天未登入算「久未登入」，預設 90 |
| `-LogPath` | 查詢紀錄位置，預設 `%LOCALAPPDATA%\ADPermissionQuery\query.log` |
| `-NoLog` | 不寫查詢紀錄 |
| `-NoGui` | 不開 Out-GridView 視窗，全部用文字選單（Server Core、遠端工作階段適用） |
| `-QueryOnly` | 只載入查詢功能（即使資料夾中有 `ADManagement.psm1`） |

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
Find-ADGroupByName -Name 'Finance'
(Get-ADUserInfo -Identity 'jdoe').Groups | Format-Table Name, Via
Compare-ADUserGroup -UserA 'jdoe' -UserB 'alice' | ForEach-Object Rows | Where-Object Result -ne '兩者都有'
Get-ADComputerInfo -Identity 'PC01'
Find-GroupFolderUsage -Group 'Finance-RW' -Path '\\fs01\share' -Depth 3
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
- 「查群組被用在哪些資料夾」只比對這個群組本身；如果它被加進其他群組，透過上層群組取得的權限不會列出。資料夾很多時掃描會比較久，建議從較小的範圍開始。
- 搜尋最多列出 200 筆，結果太多時請輸入更完整的名稱或關鍵字。

---

## 疑難排解

| 狀況 | 處理方式 |
| --- | --- |
| 雙擊後直接進入查詢，沒有「查詢 / 管理」的選擇畫面 | 同一個資料夾中找不到 `ADManagement.psm1`。畫面上會說明原因：檔案沒有一起下載，或檔名被存成 `ADManagement.psm1.txt`（檔案總管 >「檢視」> 勾選「副檔名」就看得到）。把檔案放好或改好檔名後重新開啟 |
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
- `tests\ADManagement.Tests.ps1`：讀取 Excel / CSV、預覽檢查、執行順序、還原清單、互動流程（含「輸入小寫 yes 不會執行」）
- `tests\ManagementSafety.Tests.ps1`：靜態掃描管理模組，確認修改指令只在一個函式、只有輸入大寫 YES 後才會執行
- `tests\Launcher.Tests.ps1`：模擬各種下載 / 存檔方式（有無 BOM、BOM 重複、CRLF、UTF-16LE/BE、Big5、已損壞），確認啟動腳本都能正常載入或清楚說明
