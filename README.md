# mediaconv — 照片與影片批次格式轉換

一個在 Mac / Windows 上都能用的命令列工具，可以整個資料夾（含子資料夾）一次轉換照片和影片格式。

- 📷 照片：HEIC、PNG、WebP、AVIF、TIFF、BMP、GIF ⇄ JPG（各格式之間都能互轉）
- 🎬 影片：MOV、AVI、MKV、WMV、FLV、WebM、3GP、MTS… → MP4（H.264），也能轉 MOV / MKV / WebM / GIF
- 🗂 批次處理整個資料夾，輸出時保留原本的子資料夾結構
- 🛡 **絕不修改或覆蓋原始檔案**；遇到壞檔會略過並記錄，不會整批中斷
- 📍 照片預設保留 EXIF（拍攝時間、相機、GPS），並依照方向資訊自動轉正
- 📊 顯示整體與單支影片的進度條，最後列出成功／失敗數量

---

## 安裝

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

---

## 基本用法

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
```

---

## 所有選項

| 選項 | 說明 | 預設 |
|---|---|---|
| `-o`, `--output` | 輸出資料夾，會保留子資料夾結構 | `./converted` |
| `--image-format` | 照片輸出：`jpg` `png` `webp` `heic` `avif` `tiff` `bmp` | `jpg` |
| `--video-format` | 影片輸出：`mp4` `mov` `mkv` `webm` `gif` | `mp4` |
| `--only` | `images` 只轉照片／`videos` 只轉影片 | 兩者都轉 |
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

測試會即時產生測試用的照片與影片，不需要額外素材。測試涵蓋：各格式互轉、EXIF / GPS 保留、方向轉正、縮圖、品質、透明背景、影片轉 H.264、解析度（橫式／直式／不放大）、GIF、批次與子資料夾、不覆蓋原檔、壞檔處理、撞名處理等。

### 專案結構

```
mediaconv/
├── cli.py        命令列介面、進度條、結果統計
├── converter.py  掃描資料夾、規劃輸出路徑、執行轉換
├── images.py     照片轉換（Pillow + pillow-heif）
├── videos.py     影片轉換（ffmpeg）
└── formats.py    支援的格式定義
tests/            pytest 測試
```
