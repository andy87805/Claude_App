"""支援的副檔名與輸出格式定義。"""

from __future__ import annotations

# 可讀取的照片副檔名（小寫、含點）
IMAGE_INPUT_EXTS = {
    ".jpg", ".jpeg", ".jpe", ".jfif",
    ".png",
    ".webp",
    ".heic", ".heif", ".hif",
    ".avif",
    ".tif", ".tiff",
    ".bmp",
    ".gif",  # 靜態 GIF 當照片；動態 GIF 會被當成影片處理
}

# 可讀取的影片副檔名
VIDEO_INPUT_EXTS = {
    ".mp4", ".m4v",
    ".mov", ".qt",
    ".avi",
    ".mkv",
    ".webm",
    ".wmv", ".asf",
    ".flv",
    ".3gp", ".3g2",
    ".mts", ".m2ts", ".ts",
    ".mpg", ".mpeg", ".vob",
    ".ogv",
}

# 照片輸出格式：名稱 -> (Pillow 格式名, 副檔名)
IMAGE_OUTPUT_FORMATS = {
    "jpg": ("JPEG", ".jpg"),
    "png": ("PNG", ".png"),
    "webp": ("WEBP", ".webp"),
    "heic": ("HEIF", ".heic"),
    "avif": ("AVIF", ".avif"),
    "tiff": ("TIFF", ".tiff"),
    "bmp": ("BMP", ".bmp"),
}

# 影片輸出格式 -> 副檔名
VIDEO_OUTPUT_FORMATS = {
    "mp4": ".mp4",
    "mov": ".mov",
    "mkv": ".mkv",
    "webm": ".webm",
    "gif": ".gif",
}

# 照片輸出格式的別名
IMAGE_FORMAT_ALIASES = {"jpeg": "jpg", "tif": "tiff", "heif": "heic"}

# 同一種格式的不同副檔名，用來判斷「來源已經是目標格式」
_SAME_IMAGE_FORMAT = {
    "jpg": {".jpg", ".jpeg", ".jpe", ".jfif"},
    "png": {".png"},
    "webp": {".webp"},
    "heic": {".heic", ".heif", ".hif"},
    "avif": {".avif"},
    "tiff": {".tif", ".tiff"},
    "bmp": {".bmp"},
}
_SAME_VIDEO_FORMAT = {
    "mp4": {".mp4", ".m4v"},
    "mov": {".mov", ".qt"},
    "mkv": {".mkv"},
    "webm": {".webm"},
    "gif": {".gif"},
}


def normalize_image_format(name: str) -> str:
    name = name.lower().lstrip(".")
    return IMAGE_FORMAT_ALIASES.get(name, name)


def is_same_image_format(ext: str, fmt: str) -> bool:
    return ext.lower() in _SAME_IMAGE_FORMAT.get(fmt, set())


def is_same_video_format(ext: str, fmt: str) -> bool:
    return ext.lower() in _SAME_VIDEO_FORMAT.get(fmt, set())
