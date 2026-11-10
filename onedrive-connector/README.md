# OneDrive 連接器（個人帳號）

讓 Claude 直接使用你**個人 OneDrive**（outlook.com / hotmail.com / live.com 帳號）裡的檔案。

Claude 內建的 Microsoft 365 連接器只接受公司或學校帳號，所以個人帳號需要自己架一個。這個資料夾就是那個連接器：一個跑在 Cloudflare Workers（免費方案即可）上的遠端 MCP 伺服器。架好之後，claude.ai 網頁、手機 App、Claude Code 都能用。

> 這個資料夾是完全獨立的專案，和上層的 mediaconv 無關，可以整個搬到新的 repo。

## Claude 可以做什麼

| 工具 | 用途 |
|---|---|
| `onedrive_list` | 列出資料夾裡的檔案與子資料夾 |
| `onedrive_search` | 用關鍵字搜尋整個 OneDrive |
| `onedrive_get_item` | 查看單一檔案的資訊，並取得暫時下載連結 |
| `onedrive_read_file` | 讀取檔案內容（見下表） |
| `onedrive_upload_file` | 上傳檔案（上限 4 MB；預設不會覆蓋同名檔案） |
| `onedrive_create_folder` | 建立資料夾 |

**沒有刪除、搬移、改名的功能。** 唯一會動到既有檔案的情況，是你明確要求 Claude 覆蓋同名檔案。

`onedrive_read_file` 對不同檔案的處理：

| 檔案類型 | 結果 |
|---|---|
| 文字檔（txt、md、csv、json、程式碼…） | 直接讀出文字，5 MB 以內；長檔案可分段讀 |
| Word、PowerPoint、Excel（docx／pptx／xlsx） | 抽出文字，15 MB 以內 |
| 圖片（JPG、PNG、GIF、WebP、HEIC…） | Claude 可以直接看圖；超過 1 MB 或 HEIC 會改用最長邊 1600 像素的預覽 |
| PDF、影片、其他格式 | **無法直接讀內容**，只會回傳約一小時內有效的下載連結 |

已知限制：

- **PDF 讀不到內文。** 免費方案的運算時間不夠解析 PDF。
- Excel 的日期會顯示成序號（例如 `46327`），公式只顯示上次存檔時算好的值。
- 舊版 Office 格式（.doc／.xls／.ppt）不支援。

## 安裝步驟

需要一台電腦（Mac 或 Windows）、[Node.js](https://nodejs.org/) 22 以上、一個免費的 [Cloudflare 帳號](https://dash.cloudflare.com/sign-up)，以及你的 Microsoft 帳號。全部做完大約 20 分鐘。

### 1. 部署到 Cloudflare

在這個資料夾開啟終端機：

```sh
npm install
npx wrangler login      # 會開瀏覽器請你登入 Cloudflare
npx wrangler deploy
```

第一次部署會自動建立 KV 儲存空間（用來存登入授權）；如果有詢問就回答 yes。完成後會印出你的網址，像這樣：

```
https://onedrive-connector.你的子網域.workers.dev
```

把它記下來，下面稱為「**連接器網址**」。這時連接器還不能用，因為還沒告訴它 Microsoft 的金鑰。

### 2. 在 Microsoft 註冊應用程式

這一步是向 Microsoft 取得「讓這個連接器代表你讀取 OneDrive」的許可。

1. 用你的 Microsoft 帳號登入 <https://entra.microsoft.com>，進入 **應用程式 → 應用程式註冊 → 新增註冊**（英文介面：Applications → App registrations → New registration）。
   - 如果畫面說你的帳號沒有目錄（tenant）而無法註冊，需要先用同一個帳號到 <https://azure.microsoft.com/free> 開通免費的 Azure 帳號（會要求信用卡驗證身分，註冊應用程式本身不收費），再回來這一步。
2. 填寫：
   - **名稱**：隨意，例如 `Claude OneDrive`
   - **支援的帳戶類型**：選 **僅限個人 Microsoft 帳戶**（Personal Microsoft accounts only）
   - **重新導向 URI**：平台選 **Web**，網址填 `連接器網址/callback`
     例如 `https://onedrive-connector.你的子網域.workers.dev/callback`
3. 按「註冊」。在概觀頁面複製 **應用程式（用戶端）識別碼**（Application (client) ID）。
4. 左側進入 **憑證及祕密 → 新增用戶端密碼**（Certificates & secrets → New client secret），到期時間選最長的 24 個月，建立後**立刻複製「值」**（Value，不是「祕密識別碼」）。這個值離開頁面後就看不到了。

不需要另外設定 API 權限；第一次登入時 Microsoft 會請你同意。

### 3. 把金鑰交給連接器

回到終端機，依序執行三個指令，每個都會請你貼上一個值：

```sh
npx wrangler secret put MS_CLIENT_ID       # 貼上步驟 2-3 的用戶端識別碼
npx wrangler secret put MS_CLIENT_SECRET   # 貼上步驟 2-4 的密碼「值」
npx wrangler secret put ALLOWED_EMAILS     # 貼上你的 Microsoft 帳號 email
```

`ALLOWED_EMAILS` 是允許登入的帳號名單，**只有名單上的 Microsoft 帳號能使用這個連接器**；沒設定時所有人都會被拒絕。要讓多個帳號使用時用逗號分隔。

這些值加密存放在 Cloudflare，不會出現在程式碼或 git 裡。

### 4. 在 Claude 加入連接器

1. 開啟 <https://claude.ai/customize/connectors>，新增自訂連接器。
2. 網址填 `連接器網址/mcp`，例如 `https://onedrive-connector.你的子網域.workers.dev/mcp`
3. 按「連接」。會先看到這個連接器的同意畫面，按「允許」後登入你的 Microsoft 帳號並同意權限。

完成。開一個**新的**對話（Claude Code 雲端工作階段也要開新的），就可以說「列出我 OneDrive 的文件資料夾」之類的話了。

## 之後的維護

- **Microsoft 的用戶端密碼最長 24 個月到期。** 到期後連接器會登入失敗：回到步驟 2-4 新增一組密碼，再執行一次 `npx wrangler secret put MS_CLIENT_SECRET`。
- **更新程式**：修改後再執行 `npx wrangler deploy`。
- **停用**：在 Claude 的連接器設定中斷連接；要徹底撤銷，到 <https://account.microsoft.com/privacy/app-access> 移除這個應用程式的存取權，或在 Cloudflare 後台刪除這個 Worker。

## 安全性

- 連接器只取得 OneDrive 檔案的讀寫權限（`Files.ReadWrite`）與你的基本帳號資料（`User.Read`），碰不到信箱、行事曆或其他 Microsoft 服務。
- Microsoft 的登入權杖以加密方式存在你自己的 Cloudflare KV 裡，只有持有 Claude 那一端權杖的人能解開。
- 每次連接都會顯示同意畫面，避免其他應用程式冒用這個連接器取得你的 OneDrive。
- 連接器網址本身不是祕密：沒有通過 Microsoft 登入、或帳號不在 `ALLOWED_EMAILS` 名單內的人，什麼都拿不到。
- 暫時下載連結不需登入就能下載該檔案，約一小時後失效。請當成檔案本身一樣小心，不要貼到公開的地方。

## 開發

```sh
cp .dev.vars.example .dev.vars   # 填入金鑰後可用 npm run dev 在本機執行
npm run typecheck
npm test
```

`npm test` 會在本機啟動真正的 Worker 與一個假的 Microsoft 伺服器，走完「註冊 → 同意 → 登入 → 換權杖 → 呼叫每個工具」的完整流程，不需要任何帳號。

| 檔案 | 內容 |
|---|---|
| `src/index.ts` | 進入點：OAuth 設定、`/mcp` 端點 |
| `src/auth.ts` | 同意畫面、Microsoft 登入與回呼 |
| `src/microsoft.ts` | Microsoft 登入與 Graph API 的呼叫 |
| `src/tools.ts` | 六個 OneDrive 工具 |
| `src/extract.ts` | Word／PowerPoint／Excel 文字抽取 |
