"""照片轉換（Pillow + pillow-heif）。"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageOps

from .formats import IMAGE_OUTPUT_FORMATS

try:  # 讓 Pillow 能讀寫 HEIC/HEIF
    from pillow_heif import register_heif_opener

    register_heif_opener()
    HEIF_AVAILABLE = True
except ImportError:  # pragma: no cover - 依安裝環境而定
    HEIF_AVAILABLE = False

# 超大圖片（例如全景照）不要被 Pillow 當成解壓縮炸彈擋下來
Image.MAX_IMAGE_PIXELS = None

ORIENTATION_TAG = 0x0112

# 哪些輸出格式可以寫入 EXIF
_EXIF_CAPABLE = {"JPEG", "PNG", "WEBP", "HEIF", "AVIF", "TIFF"}
# 哪些輸出格式支援透明
_ALPHA_CAPABLE = {"PNG", "WEBP", "HEIF", "AVIF", "TIFF"}


class ImageConversionError(Exception):
    pass


def is_animated(path: Path) -> bool:
    """判斷檔案是否為多影格動畫（例如動態 GIF）。"""
    try:
        with Image.open(path) as img:
            return getattr(img, "n_frames", 1) > 1
    except Exception:
        return False


def verify_image(path: Path) -> None:
    """確認照片能完整解碼，壞檔會丟出 ImageConversionError。"""
    try:
        with Image.open(path) as img:
            img.load()
    except Exception as exc:
        raise ImageConversionError(f"無法讀取照片：{exc}") from exc


def _flatten_alpha(img: Image.Image, background=(255, 255, 255)) -> Image.Image:
    """把透明背景合成到白底上（JPG/BMP 不支援透明）。"""
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        rgba = img.convert("RGBA")
        base = Image.new("RGB", rgba.size, background)
        base.paste(rgba, mask=rgba.getchannel("A"))
        return base
    return img.convert("RGB")


def _prepare_mode(img: Image.Image, pil_format: str) -> Image.Image:
    has_alpha = img.mode in ("RGBA", "LA", "PA") or (
        img.mode == "P" and "transparency" in img.info
    )
    if pil_format in _ALPHA_CAPABLE and has_alpha:
        return img if img.mode == "RGBA" else img.convert("RGBA")
    if pil_format == "TIFF" and img.mode in ("RGB", "L", "CMYK"):
        return img
    if pil_format == "PNG" and img.mode in ("RGB", "L"):
        return img
    if img.mode == "CMYK":
        return img.convert("RGB")
    # 16 位元灰階等特殊模式先轉成 8 位元
    if img.mode.startswith("I") or img.mode == "F":
        img = img.convert("I").point(lambda v: v * (1 / 256)).convert("L")
    return _flatten_alpha(img)


def _resize(img: Image.Image, max_size: int | None) -> Image.Image:
    if not max_size:
        return img
    w, h = img.size
    longest = max(w, h)
    if longest <= max_size:  # 只縮小、不放大
        return img
    scale = max_size / longest
    new_size = (max(1, round(w * scale)), max(1, round(h * scale)))
    return img.resize(new_size, Image.Resampling.LANCZOS)


def load_image(src: Path, max_size: int | None, pil_format: str):
    """讀取照片、依 EXIF 轉正、縮小、轉成適合輸出格式的色彩模式。回傳 (影像, EXIF, ICC)。"""
    try:
        with Image.open(src) as opened:
            opened.load()
            exif = opened.getexif()
            icc = opened.info.get("icc_profile")
            img = ImageOps.exif_transpose(opened) or opened
            img = _resize(img, max_size)
            img = _prepare_mode(img, pil_format)
    except Exception as exc:
        raise ImageConversionError(f"無法讀取照片：{exc}") from exc
    return img, exif, icc


def metadata_kwargs(exif, icc, pil_format: str, keep_metadata: bool) -> dict:
    kwargs: dict = {}
    if keep_metadata:
        if pil_format in _EXIF_CAPABLE and len(exif):
            if ORIENTATION_TAG in exif:
                exif[ORIENTATION_TAG] = 1
            kwargs["exif"] = exif.tobytes()
        if icc and pil_format != "BMP":
            kwargs["icc_profile"] = icc
    return kwargs


def jpeg_kwargs(quality: int) -> dict:
    return {"quality": quality, "optimize": True, "subsampling": "4:2:0" if quality < 90 else "4:4:4"}


def convert_image(
    src: Path,
    dst: Path,
    fmt: str,
    quality: int = 85,
    max_size: int | None = None,
    keep_metadata: bool = True,
) -> None:
    """把 src 轉成 fmt 格式寫到 dst。

    - 依 EXIF 方向自動轉正，並把方向標記重設為 1，避免看圖軟體再轉一次
    - 預設保留 EXIF（拍攝時間、GPS 等）與 ICC 色彩描述檔
    """
    if fmt not in IMAGE_OUTPUT_FORMATS:
        raise ImageConversionError(f"不支援的照片輸出格式：{fmt}")
    pil_format, _ = IMAGE_OUTPUT_FORMATS[fmt]
    if pil_format == "HEIF" and not HEIF_AVAILABLE:
        raise ImageConversionError("未安裝 pillow-heif，無法輸出 HEIC")

    img, exif, icc = load_image(src, max_size, pil_format)
    save_kwargs = metadata_kwargs(exif, icc, pil_format, keep_metadata)

    if pil_format == "JPEG":
        save_kwargs.update(jpeg_kwargs(quality))
    elif pil_format in ("WEBP", "HEIF", "AVIF"):
        save_kwargs["quality"] = quality
    elif pil_format == "PNG":
        save_kwargs["optimize"] = True
    elif pil_format == "TIFF" and "exif" not in save_kwargs:
        # libtiff 壓縮時寫不進 EXIF 子目錄，所以有 EXIF 時存成不壓縮的 TIFF
        save_kwargs["compression"] = "tiff_lzw"

    try:
        img.save(dst, format=pil_format, **save_kwargs)
    except Exception as exc:
        raise ImageConversionError(f"寫入失敗：{exc}") from exc
