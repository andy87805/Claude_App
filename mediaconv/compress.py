"""壓縮模式：讓照片、影片、PDF 變小。

- 照片：縮小解析度 + 較低品質的 JPG
- 影片：H.264 + 較低解析度與位元率
- 有設定每個檔案的上限（target_size）時，先照壓縮程度處理，超過上限才再壓得更小
- PDF：有 Ghostscript 就用它（效果最好），沒有則用 pikepdf 重新壓縮 PDF 裡的圖片
"""

from __future__ import annotations

import io
import re
import shutil
import subprocess
from pathlib import Path
from typing import Callable

from . import images, videos

LEVELS = ("light", "standard", "strong")
LEVEL_NAMES = {"light": "輕度", "standard": "標準", "strong": "強力"}

# 照片：(最長邊, JPG 品質)
IMAGE_PRESETS = {"light": (3000, 80), "standard": (2048, 75), "strong": (1280, 65)}

# 影片：短邊、CRF、最高位元率、聲音位元率
VIDEO_PRESETS = {
    "light": {"short": 1080, "crf": 26, "maxrate": 5_000_000, "audio": 128_000},
    "standard": {"short": 720, "crf": 28, "maxrate": 2_500_000, "audio": 128_000},
    "strong": {"short": 480, "crf": 30, "maxrate": 1_000_000, "audio": 96_000},
}

# PDF：Ghostscript 的預設組合；pikepdf 備援時圖片的 (最長邊, JPG 品質)
PDF_GS_SETTINGS = {"light": "/printer", "standard": "/ebook", "strong": "/screen"}
PDF_IMAGE_PRESETS = {"light": (2400, 80), "standard": (1600, 70), "strong": (1100, 55)}

_SIZE_RE = re.compile(r"^\s*([\d.]+)\s*([kmg]?)i?b?\s*$", re.IGNORECASE)


class CompressionError(Exception):
    pass


def parse_size(text: str) -> int:
    """'25MB' / '800KB' / '1.5G' / '10'（預設 MB）-> 位元組數。"""
    m = _SIZE_RE.match(text)
    if not m:
        raise ValueError(f"看不懂的大小：{text}（例如 25MB、800KB）")
    number, unit = float(m.group(1)), (m.group(2) or "m").lower()
    value = int(number * {"k": 1024, "m": 1024**2, "g": 1024**3}[unit])
    if value <= 0:
        raise ValueError("大小必須大於 0")
    return value


def format_size(n: int) -> str:
    if n < 1024**2:
        return f"{n / 1024:.0f} KB"
    return f"{n / 1024**2:.1f} MB"


# ---------------- 照片 ----------------


def _encode_jpeg(img, quality: int, meta: dict) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="JPEG", **meta, **images.jpeg_kwargs(quality))
    return buf.getvalue()


def compress_image(
    src: Path,
    dst: Path,
    level: str = "standard",
    target_size: int | None = None,
    keep_metadata: bool = True,
) -> list[str]:
    """壓縮照片成 JPG，回傳提示訊息。"""
    max_size, quality = IMAGE_PRESETS[level]
    notes: list[str] = []

    # 先照壓縮程度處理；有設定上限而且超過時，才再壓得更小
    img, exif, icc = images.load_image(src, max_size, "JPEG")
    meta = images.metadata_kwargs(exif, icc, "JPEG", keep_metadata)
    first = _encode_jpeg(img, quality, meta)
    if not target_size or len(first) <= target_size:
        dst.write_bytes(first)
        return notes

    # 超過上限：找出符合大小的最高品質，不夠小就逐步縮小尺寸
    base = img
    best: bytes | None = None
    scale = 1.0
    for _ in range(8):
        if scale < 1.0:
            w, h = base.size
            img = base.resize((max(1, round(w * scale)), max(1, round(h * scale))), images.Image.Resampling.LANCZOS)
        lo, hi, found = 40, 90, None
        while lo <= hi:
            q = (lo + hi) // 2
            data = _encode_jpeg(img, q, meta)
            if len(data) <= target_size:
                found, lo = data, q + 1
            else:
                hi = q - 1
        if found:
            best = found
            break
        scale *= 0.75
    if best is None:
        best = _encode_jpeg(img, 40, meta)
        notes.append(f"無法壓到 {format_size(target_size)} 以下，已盡量壓縮")
    elif scale < 1.0:
        notes.append(f"為了符合目標大小，尺寸縮小為 {img.size[0]}×{img.size[1]}")
    dst.write_bytes(best)
    return notes


# ---------------- 影片 ----------------


def _video_command(src: Path, dst: Path, short: int, audio: int, keep_metadata: bool,
                   crf: int | None = None, bitrate: int | None = None, maxrate: int | None = None) -> list[str]:
    cmd = [videos.find_ffmpeg(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", str(src),
           "-map", "0:v:0", "-map", "0:a?", "-sn", "-dn",
           "-vf", videos._scale_filter(f"{short}p"),
           "-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p"]
    if bitrate:
        cmd += ["-b:v", str(bitrate), "-maxrate", str(int(bitrate * 1.3)), "-bufsize", str(bitrate * 2)]
    else:
        cmd += ["-crf", str(crf), "-maxrate", str(maxrate), "-bufsize", str(maxrate * 2)]
    cmd += ["-c:a", "aac", "-b:a", str(audio), "-ac", "2"]
    cmd += ["-map_metadata", "0" if keep_metadata else "-1",
            "-movflags", "+faststart" + ("+use_metadata_tags" if keep_metadata else ""),
            "-f", "mp4", "-progress", "pipe:1", "-nostats", str(dst)]
    return cmd


def _short_side_for_bitrate(bps: int) -> int:
    if bps >= 4_500_000:
        return 1080
    if bps >= 2_000_000:
        return 720
    if bps >= 900_000:
        return 480
    return 360


def compress_video(
    src: Path,
    dst: Path,
    level: str = "standard",
    target_size: int | None = None,
    keep_metadata: bool = True,
    on_progress: Callable[[float, float | None], None] | None = None,
) -> list[str]:
    preset = VIDEO_PRESETS[level]
    duration = videos.probe(src)["duration"]
    notes: list[str] = []

    bitrate = None
    if target_size:
        if not duration:
            raise CompressionError("讀不到影片長度，無法依目標大小壓縮")
        audio = 96_000
        # 符合上限的位元率（保留 4% 給檔案格式本身的額外空間）
        bitrate = int(target_size * 8 * 0.96 / duration) - audio
        if bitrate < 150_000:
            raise CompressionError(
                f"目標大小太小：{duration:.0f} 秒的影片至少需要約 "
                f"{format_size(int((150_000 + audio) * duration / 8 / 0.96))}"
            )
        if bitrate >= preset["maxrate"]:
            bitrate = None  # 上限很寬鬆，照壓縮程度處理就好

    if bitrate is None:
        cmd = _video_command(src, dst, preset["short"], preset["audio"], keep_metadata,
                             crf=preset["crf"], maxrate=preset["maxrate"])
        videos.run_ffmpeg(cmd, dst, duration, on_progress)
        if not target_size or dst.stat().st_size <= target_size:
            return notes
        bitrate = int(preset["maxrate"] * target_size / dst.stat().st_size * 0.92)

    short = min(preset["short"], _short_side_for_bitrate(bitrate))
    for attempt in range(3):
        cmd = _video_command(src, dst, short, audio, keep_metadata, bitrate=bitrate)
        videos.run_ffmpeg(cmd, dst, duration, on_progress)
        size = dst.stat().st_size
        if size <= target_size:
            break
        # 超過目標就依比例再降一點位元率重來
        bitrate = int(bitrate * target_size / size * 0.92)
    else:
        notes.append(f"無法完全壓到 {format_size(target_size)} 以下")
    return notes


# ---------------- PDF ----------------


def find_ghostscript() -> str | None:
    for name in ("gs", "gswin64c", "gswin32c"):
        path = shutil.which(name)
        if path:
            return path
    return None


def _pdf_with_ghostscript(gs: str, src: Path, dst: Path, level: str) -> None:
    cmd = [
        gs, "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.5",
        f"-dPDFSETTINGS={PDF_GS_SETTINGS[level]}",
        "-dNOPAUSE", "-dQUIET", "-dBATCH", "-dSAFER",
        "-dDetectDuplicateImages=true", "-dCompressFonts=true",
        f"-sOutputFile={dst}", str(src),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if proc.returncode != 0 or not dst.exists() or dst.stat().st_size == 0:
        detail = (proc.stderr or proc.stdout).strip().splitlines()[-1:] or ["未知錯誤"]
        raise CompressionError(f"Ghostscript 失敗：{detail[0]}")


def _pdf_with_pikepdf(src: Path, dst: Path, level: str) -> None:
    try:
        import pikepdf
        from pikepdf import Name, PdfImage
    except ImportError as exc:  # pragma: no cover
        raise CompressionError("需要安裝 pikepdf 或 Ghostscript 才能壓縮 PDF") from exc

    max_side, quality = PDF_IMAGE_PRESETS[level]
    try:
        pdf = pikepdf.open(src)
    except pikepdf.PasswordError as exc:
        raise CompressionError("這個 PDF 有密碼保護，無法壓縮") from exc
    except Exception as exc:
        raise CompressionError(f"無法讀取 PDF：{exc}") from exc

    with pdf:
        for obj in pdf.objects:
            if not isinstance(obj, pikepdf.Stream) or obj.get("/Subtype") != Name.Image:
                continue
            if obj.get("/ImageMask") or "/Decode" in obj or "/Mask" in obj:
                continue
            try:
                pil = PdfImage(obj).as_pil_image()
            except Exception:
                continue  # 特殊格式的圖片就保持原樣
            if pil.mode not in ("RGB", "L"):
                if pil.mode in ("CMYK", "P", "LA", "RGBA", "I;16"):
                    pil = pil.convert("RGB")
                else:
                    continue
            w, h = pil.size
            if max(w, h) > max_side:
                s = max_side / max(w, h)
                pil = pil.resize((max(1, round(w * s)), max(1, round(h * s))), images.Image.Resampling.LANCZOS)
            buf = io.BytesIO()
            pil.save(buf, format="JPEG", **images.jpeg_kwargs(quality))
            data = buf.getvalue()
            if len(data) >= len(obj.read_raw_bytes()):
                continue  # 沒有變小就不換
            obj.write(data, filter=Name.DCTDecode)
            obj.Width, obj.Height = pil.size
            obj.ColorSpace = Name.DeviceGray if pil.mode == "L" else Name.DeviceRGB
            obj.BitsPerComponent = 8
            for key in ("/DecodeParms", "/SMaskInData"):
                if key in obj:
                    del obj[key]
        pdf.remove_unreferenced_resources()
        pdf.save(dst, compress_streams=True, recompress_flate=True,
                 object_stream_mode=pikepdf.ObjectStreamMode.generate)


def _compress_pdf_once(src: Path, dst: Path, level: str) -> None:
    gs = find_ghostscript()
    if gs:
        try:
            _pdf_with_ghostscript(gs, src, dst, level)
        except CompressionError:
            pass  # Ghostscript 處理不了的 PDF，改用 pikepdf 再試
        else:
            if dst.stat().st_size <= src.stat().st_size * 0.9:
                return
            # Ghostscript 只會降低解析度，不會降低 JPG 品質；
            # 解析度本來就不高的掃描檔幾乎不會變小，所以再用 pikepdf 試一次，取比較小的
            alt = dst.with_name(dst.stem + ".alt" + dst.suffix)
            try:
                _pdf_with_pikepdf(src, alt, level)
                if alt.stat().st_size < dst.stat().st_size:
                    alt.replace(dst)
            except CompressionError:
                pass
            finally:
                if alt.exists():
                    alt.unlink()
            return
    _pdf_with_pikepdf(src, dst, level)


def compress_pdf(src: Path, dst: Path, level: str = "standard", target_size: int | None = None) -> list[str]:
    if not target_size:
        _compress_pdf_once(src, dst, level)
        return []
    # 有設定上限：從選擇的程度開始，超過上限就改用更強的程度
    smallest: bytes | None = None
    for lv in LEVELS[LEVELS.index(level):]:
        _compress_pdf_once(src, dst, lv)
        data = dst.read_bytes()
        if len(data) <= target_size:
            return [] if lv == level else [f"為了符合上限，改用「{LEVEL_NAMES[lv]}」壓縮"]
        if smallest is None or len(data) < len(smallest):
            smallest = data
    dst.write_bytes(smallest)
    return [f"無法壓到 {format_size(target_size)} 以下，已盡量壓縮"]
