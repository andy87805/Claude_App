# mediaconv — 照片、影片格式轉換與壓縮

一個在 Mac / Windows 上都能用的命令列工具，可以整個資料夾（含子資料夾）一次轉換照片和影片格式，也能**壓縮照片、影片和 PDF**。另外還有在 iPhone 上就能用的網頁版。

- 📷 照片：HEIC、PNG、WebP、AVIF、TIFF、BMP、GIF ⇄ JPG（各格式之間都能互轉）
- 🎬 影片：MOV、AVI、MKV、WMV、FLV、WebM、3GP、MTS… → MP4（H.264），也能轉 MOV / MKV / WebM / GIF
- 🗜 壓縮模式：讓照片、影片、PDF 變小，可選壓縮程度或指定每個檔案的上限（例如 25 MB）
- 🗂 批次處理整個資料夾，輸出時保留原本的子資料夾結構
- 🛡 **絕不修改或覆蓋原始檔案**；遇到壞檔會略過並記錄，不會整批中斷
- 📍 照片預設保留 EXIF（拍攝時間、相機、GPS），並依照方向資訊自動轉正
- 📊 顯示整體與單支影片的進度條，最後列出成功／失敗數量

> 📱 **想在 iPhone 上用？** 請看下方的[網頁版](#網頁版iphone--任何瀏覽器)，不用安裝任何東西。

---

## 網頁版（iPhone / 任何瀏覽器）

網址：**<https://andy87805.github.io/Claude_App/>**

- 所有轉換都在手機上完成，**照片和影片不會上傳到任何地方**
- 用 Safari 開啟後點「分享」→「加入主畫面」，就像 App 一樣，而且**離線也能用**
- 照片：HEIC / PNG / WebP / JPG… → **JPG、PNG、WebP**；保留拍攝時間、GPS，並自動轉正
- 影片：MOV / MP4 / MKV / WebM → **MP4、MOV（H.264）、WebM、GIF**；可選解析度與畫質
- **壓縮檔案**模式：照片、影片、PDF 都能壓縮（見下方[壓縮功能](#壓縮功能)）
- **去背**模式：用 AI 自動去掉照片背景，輸出透明 PNG，或換成白色、黑色、自訂顏色的底（見下方[去背](#去背)）
- 「拍攝資訊」可選全部保留、**只移除 GPS 位置**（分享給別人時建議用），或全部移除
- 轉好後按「儲存」會開啟 iPhone 的分享選單，選「儲存影像／儲存影片」就會存回相簿
- 「全部下載」：多個檔案會打包成一個 ZIP（iPhone 會存到「檔案」App），只有一個檔案時直接下載
- 選錯檔案可以按右邊的 ✕ 個別移除
- 完成後點擊檔案可以預覽：照片（點兩下放大）、影片、PDF 每一頁；可切換「結果／原檔」比較畫質，左右滑動或按箭頭切換檔案
- 介面採用 iPhone 原生風格，支援淺色／深色模式；有流暢的過場動畫，系統開啟「減少動態效果」時會自動關閉動畫

### 和電腦版的差異

| | 電腦版（命令列） | 網頁版 |
|---|---|---|
| 照片輸出格式 | JPG、PNG、WebP、HEIC、AVIF、TIFF、BMP | JPG、PNG、WebP |
| 影片輸入格式 | 幾乎所有格式（含 AVI、WMV、FLV） | MP4、MOV、MKV、WebM（不支援 AVI、WMV、FLV） |
| 影片長度 | 不限 | 建議 1–2 分鐘以內（受手機記憶體限制） |
| 整個資料夾批次處理 | ✅ | 一次選多個檔案 |
| PDF 壓縮 | Ghostscript（效果最好），沒裝時自動改用內建方式 | 重新壓縮 PDF 裡的圖片；強力模式每頁轉圖片 |

### 小細節
- 如果影片已經是 H.264、不用縮小、畫質選「高」，會直接搬移影像資料，**幾乎瞬間完成、畫質零損失**。選「中」「低」才會重新壓縮讓檔案變小。
- iPhone 瀏覽器的圖片上限約 1600 萬像素；4800 萬或 2400 萬像素的照片會自動縮小到上限內，並在畫面上提示。
- 轉換時會讓螢幕保持不關閉；請不要切換到其他 App，否則 iOS 可能暫停轉換。

### 部署方式（網頁版）

推送到 `master` 時，GitHub Actions（`.github/workflows/pages.yml`）會自動把 `web/` 資料夾發佈到 GitHub Pages。
第一次需要在 repo 的 **Settings → Pages → Build and deployment → Source** 選 **GitHub Actions**。

---

## 壓縮功能

網頁版切換到「**壓縮檔案**」，電腦版加上 `--compress`。三種程度：

| 程度 | 照片（存成 JPG） | 影片（存成 MP4 / H.264） | PDF |
|---|---|---|---|
| 輕度 | 最長邊 3000、品質 80 | 1080p，約 5 Mbps | 圖片降到約 300 dpi／2400 像素 |
| **標準**（預設） | 最長邊 2048、品質 75 | 720p，約 2.5 Mbps | 圖片降到約 150 dpi／1600 像素 |
| 強力 | 最長邊 1280、品質 65 | 480p，約 1 Mbps | 電腦版：圖片降到約 72 dpi；網頁版：每一頁轉成圖片（文字無法選取） |

- **每個檔案上限**（網頁版的下拉選單、電腦版的 `--target-size 25MB`）：先照選的程度壓縮，還是超過上限時才自動壓得更小。照片會降低品質、必要時再縮小尺寸；影片會依長度算出位元率；PDF 會改用更強的程度。
- **壓縮後沒有變小的檔案會保留原檔**（副檔名也不變），所以不用擔心越壓越大。
- 拍攝時間、GPS 的保留或移除，和轉換模式的設定相同。
- PDF 的效果差很多：**掃描檔、照片多的 PDF 通常能小 50–90%**；純文字 PDF 本來就小，幾乎不會變小。
- 有密碼保護的 PDF 無法壓縮。

### 為什麼 HEIC 轉 PNG 會變大好幾倍？

HEIC 是效率很高的**有損**壓縮；PNG 是**無損**格式，每個像素都原封不動記錄下來，所以照片轉 PNG 通常會大 5–10 倍，而且 HEIC 已經損失的細節也救不回來。照片請用 JPG（相容性最好）或 WebP；PNG 適合截圖、圖表和需要透明背景的圖。

---

## 去背

網頁版切換到「**去背**」，選照片後按「開始去背」。

- 使用 [RMBG-1.4](https://huggingface.co/briaai/RMBG-1.4) AI 模型，**在手機上執行，照片不會上傳**。人物、動物、商品等各種主體都適用。
- 背景可選：**透明**（輸出 PNG，可直接貼到其他圖片或簡報）、**白色**、**黑色**或**自訂顏色**（輸出 JPG）。
- 可以限制輸出尺寸（例如最長邊 1080 適合社群、512 適合貼圖）；拍攝資訊依設定保留或移除。
- 第一次使用需要下載約 **110 MB**（模型約 84 MB＋執行程式約 28 MB），建議連 Wi-Fi；之後會存在瀏覽器裡，離線也能用。
- 每張照片約需 5–20 秒，視手機效能而定。網站會透過 service worker 開啟「跨來源隔離」，讓模型可以用多執行緒執行（約快 2 倍）。
- 模型選用 fp16 版本：比 42 MB 的量化版大一倍，但量化版去背後背景會留下很多雜點。
- RMBG-1.4 的授權為**非商業用途免費**（[bria-rmbg-1.4 授權](https://huggingface.co/briaai/RMBG-1.4)）。個人使用沒問題；若要用於商業用途，需另外向 Bria AI 取得授權。

---

## 電腦版安裝

需要 **Python 3.9 以上**。

### 1. 安裝 Python

- **Mac**：`brew install python`，或從 <https://www.python.org/downloads/> 下載
- **Windows**：從 <https://www.python.org/downloads/> 下載，安裝時記得勾選 **「Add python.exe to PATH」**

### 2. 安裝 mediaconv

```bash
git clone https://github.com/andy87805/Claude_App.git
cd Claude_App
pip install .
```

> Windows 若 `pip` 指令找不到，改用 `py -m pip install .`

### 3. ffmpeg（處理影片用）

安裝 mediaconv 時會自動附帶一份 ffmpeg（透過 `imageio-ffmpeg`），**通常不用另外安裝**。
如果系統已經裝了 ffmpeg，會優先使用系統的版本。想自行安裝的話：

- Mac：`brew install ffmpeg`
- Windows：`winget install ffmpeg`

### 4. Ghostscript（選用，壓縮 PDF 效果更好）

沒有安裝也能壓縮 PDF（會改用內建的 pikepdf 重新壓縮 PDF 裡的圖片），但裝了 Ghostscript 效果更好：

- Mac：`brew install ghostscript`
- Windows：`winget install ArtifexSoftware.GhostScript`，或從 <https://ghostscript.com/releases/gsdnld.html> 下載

---

## 電腦版用法

```bash
mediaconv <檔案或資料夾> -o <輸出資料夾> [選項]
```

不加任何選項時：**照片 → JPG（品質 85）、影片 → MP4（H.264）**，輸出到 `./converted`。

> 如果 `mediaconv` 指令找不到，可以改用 `python -m mediaconv`（Windows：`py -m mediaconv`）。

### 常用範例

```bash
# 整個 iPhone 匯出資料夾：HEIC → JPG、MOV → MP4
mediaconv ~/Pictures/iPhone -o ~/Desktop/converted

# Windows 路徑也一樣
mediaconv "D:\相片\2024 旅遊" -o "D:\轉檔結果"

# 反向轉換：照片轉成 PNG / WebP / HEIC
mediaconv photos -o out --image-format png
mediaconv photos -o out --image-format webp --quality 80

# 縮小照片：最長邊 1920 像素、品質 75（適合傳 LINE、上傳網路）
mediaconv photos -o out --max-size 1920 -q 75

# 影片轉成 720p MP4
mediaconv videos -o out -r 720p

# 把影片第 3 秒開始的 5 秒做成 GIF
mediaconv clip.mov -o out --video-format gif --start 3 --duration 5

# 分享給別人前，移除照片中的 GPS 等個人資訊
mediaconv photos -o share --strip-metadata

# 先看看會做什麼，不實際轉換
mediaconv photos -o out --dry-run

# 壓縮整個資料夾（照片、影片、PDF 都會處理）
mediaconv ~/Documents/要寄的檔案 -o ~/Desktop/small --compress

# 強力壓縮掃描的 PDF
mediaconv scan.pdf -o small --compress --level strong

# 每個檔案壓到 25 MB 以內（email 附件上限）
mediaconv video.mov report.pdf -o small --compress --target-size 25MB
```

---

## 所有選項

| 選項 | 說明 | 預設 |
|---|---|---|
| `-o`, `--output` | 輸出資料夾，會保留子資料夾結構 | `./converted` |
| `--image-format` | 照片輸出：`jpg` `png` `webp` `heic` `avif` `tiff` `bmp` | `jpg` |
| `--video-format` | 影片輸出：`mp4` `mov` `mkv` `webm` `gif` | `mp4` |
| `--only` | `images` 只處理照片／`videos` 只處理影片／`pdfs` 只處理 PDF（壓縮模式） | 全部 |
| `--no-recursive` | 不處理子資料夾 | 會處理 |
| **照片** | | |
| `-q`, `--quality` | 品質 1–100（JPG / WebP / HEIC / AVIF） | `85` |
| `--max-size` | 最長邊像素上限（只縮小不放大） | 不縮放 |
| `--strip-metadata` | 移除 EXIF（拍攝時間、GPS…） | 保留 |
| **影片** | | |
| `-r`, `--resolution` | `360p` `480p` `720p` `1080p` `1440p` `4k`（只縮小不放大，直式影片也正確） | 原尺寸 |
| `--crf` | 畫質，數字越小越清楚、檔案越大（H.264 常用 18–28） | H.264：23；WebM：32 |
| `--preset` | 編碼速度 `ultrafast` … `veryslow`，越慢檔案越小 | `medium` |
| `--start` / `--duration` | 從第幾秒開始／只轉幾秒 | 整支 |
| `--gif-fps` / `--gif-width` | GIF 每秒張數／寬度 | `12` / `480` |
| **壓縮** | | |
| `--compress` | 壓縮模式：照片存成 JPG、影片存成 MP4，也會處理 PDF | 關閉 |
| `--level` | 壓縮程度：`light` 輕度、`standard` 標準、`strong` 強力 | `standard` |
| `--target-size` | 每個檔案的上限，例如 `25MB`、`800KB` | 不限 |
| **其他** | | |
| `--on-exists` | 輸出資料夾已有同名檔：`skip` 略過、`rename` 另存 `_1`、`overwrite` 覆蓋**輸出檔** | `skip` |
| `--reencode` | 來源已是目標格式時也重新壓縮 | 直接複製 |
| `-n`, `--dry-run` | 只列出計畫，不轉換 | |

完整說明：`mediaconv --help`

---

## 運作細節

### 安全性
- 原始檔只會被讀取，**永遠不會被修改、移動或覆蓋**。
- 輸出資料夾不能和輸入資料夾相同；如果輸出資料夾放在輸入資料夾裡面，會自動排除，不會被重複轉換。
- 轉換時先寫到暫存檔，成功後才改成正式檔名，所以中途失敗或按 Ctrl+C 不會留下壞掉的檔案。
- 預設 `--on-exists skip`：已經轉過的檔案會略過，**中斷後重新執行同一個指令就能接著做**。

### 壞檔與紀錄
- 讀不了的檔案會被略過，其他檔案照常轉換。
- 結束時列出失敗清單，並在輸出資料夾寫入 `mediaconv-errors-日期時間.log`。
- 結束代碼：`0` 全部成功、`1` 有檔案失敗、`2` 參數錯誤、`130` 被中斷。

### 照片
- 依照 EXIF 方向自動轉正（例如手機直拍的照片），並把方向標記重設，避免看圖軟體再轉一次。
- 保留 EXIF（拍攝時間、相機型號、GPS）與 ICC 色彩描述檔（iPhone 的 Display P3 色彩不會跑掉）。
- 轉成 JPG / BMP 時，透明背景會變成白色；PNG / WebP / HEIC / AVIF / TIFF 會保留透明。
- 動態 GIF 會被當成影片處理（預設轉成 MP4）；靜態 GIF 當成照片。
- BMP 格式本身不支援 EXIF；為了保留 EXIF，TIFF 會存成不壓縮的格式。

### 影片
- MP4 / MOV / MKV 使用 H.264 + AAC，幾乎所有裝置、瀏覽器、剪輯軟體都能播放。
- 保留拍攝時間等中繼資料，手機影片的旋轉方向會自動處理。
- 解析度選項會自動判斷橫式或直式，例如 720p：橫式 → 1280×720、直式 → 720×1280。
- 如果來源已經是目標格式（例如已經是 H.264 的 MP4），預設直接複製，不會重新壓縮而損失畫質。
- GIF 使用調色盤最佳化，畫質比一般直接轉換好很多。長影片轉 GIF 檔案會很大，建議搭配 `--duration`。

### 已知限制
- iPhone 的 HDR（杜比視界）影片轉成 H.264 後是一般 SDR 色彩，畫面可能看起來比較灰淡。
- 影片中的字幕軌不會被轉換。

---

## 開發與測試

```bash
pip install -e ".[dev]"
pytest
```

測試會即時產生測試用的照片與影片，不需要額外素材。測試涵蓋：各格式互轉、EXIF / GPS 保留、方向轉正、縮圖、品質、透明背景、影片轉 H.264、解析度（橫式／直式／不放大）、GIF、批次與子資料夾、不覆蓋原檔、壞檔處理、撞名處理，以及照片／影片／PDF 壓縮（各程度、目標大小、變大時保留原檔、加密 PDF）等。

### 網頁版測試

網頁版的測試會用 Playwright 開啟真的瀏覽器，選檔、轉換，再用 Python 檢查輸出的檔案（格式、尺寸、EXIF、方向、影音編碼）。

```bash
npm install playwright && npx playwright install chromium
pip install -e ".[dev]"   # 測試用 Pillow 檢查輸出
node --test tests/web/e2e.test.mjs
```

本機預覽網頁版：`python -m http.server -d web 8000`，然後開 <http://localhost:8000>。

### 專案結構

```
mediaconv/            電腦版（Python）
├── cli.py            命令列介面、進度條、結果統計
├── converter.py      掃描資料夾、規劃輸出路徑、執行轉換
├── images.py         照片轉換（Pillow + pillow-heif）
├── videos.py         影片轉換（ffmpeg）
├── compress.py       壓縮模式（照片、影片、PDF）
└── formats.py        支援的格式定義
web/                  網頁版（純前端，不需要建置）
├── index.html
├── css/style.css
├── js/app.js         介面、檔案清單、儲存／分享
├── js/image.js       照片轉換與壓縮（瀏覽器解碼 + canvas）
├── js/exif.js        讀取／修改／寫入 EXIF（JPEG、PNG、WebP、HEIC）
├── js/video.js       影片轉換與壓縮（Mediabunny / WebCodecs）、GIF
├── js/pdf.js         PDF 壓縮與預覽（pdf-lib / PDF.js）
├── js/bgremove.js    去背（Transformers.js + RMBG-1.4）
├── js/preview.js     預覽視窗
├── js/zip.js         全部下載時打包成 ZIP
├── sw.js             離線快取
└── vendor/           第三方函式庫（授權條款見 vendor/licenses/）
tests/                電腦版 pytest 測試
tests/web/            網頁版端對端測試
```

### 網頁版使用的開源套件

| 套件 | 用途 | 授權 |
|---|---|---|
| [Mediabunny](https://mediabunny.dev) 1.61.4 | 影片讀取、轉檔、封裝 | MPL-2.0 |
| @mediabunny/aac-encoder 1.61.4 | 瀏覽器不能編碼 AAC 時的備援 | MPL-2.0 |
| [gifenc](https://github.com/mattdesl/gifenc) 1.0.3 | GIF 編碼 | MIT |
| [heic-to](https://github.com/hoppergee/heic-to) 1.6.6 | 非 Safari 瀏覽器讀取 HEIC 的備援 | LGPL-3.0 |
| [pdf-lib](https://pdf-lib.js.org) 1.17.1 | 讀寫 PDF、替換圖片 | MIT |
| [PDF.js](https://mozilla.github.io/pdf.js/) 6.4.299 | 強力壓縮時把 PDF 頁面轉成圖片、PDF 預覽 | Apache-2.0 |
| [Transformers.js](https://huggingface.co/docs/transformers.js) 4.3.1 | 在瀏覽器執行去背 AI 模型（Transformers.js 與 ONNX Runtime 從 jsDelivr CDN 載入，不在 repo 裡） | Apache-2.0 / MIT |
| [RMBG-1.4](https://huggingface.co/briaai/RMBG-1.4) 模型 | 去背（使用時從 Hugging Face 下載，不在 repo 裡） | 非商業用途免費 |
| [@jsquash/webp](https://github.com/jamsinclair/jSquash) 1.5.0 | Safari 不能輸出 WebP 時的備援 | Apache-2.0 |
