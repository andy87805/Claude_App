"""測試用的照片與影片在測試時即時產生，不需要放任何素材檔。"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from PIL import Image

from mediaconv import images  # noqa: F401 - 註冊 HEIC 讀寫
from mediaconv.videos import find_ffmpeg

TAKEN_AT = "2024:05:01 10:20:30"
GPS = {1: "N", 2: (25.0, 2.0, 30.0), 3: "E", 4: (121.0, 33.0, 15.0)}


def make_exif(orientation: int = 1) -> bytes:
    exif = Image.Exif()
    exif[0x0112] = orientation
    exif[0x010F] = "TestCam"
    exif.get_ifd(0x8769)[0x9003] = TAKEN_AT  # DateTimeOriginal
    exif.get_ifd(0x8825).update(GPS)
    return exif.tobytes()


def make_photo(path: Path, size=(400, 300), orientation: int = 1, fmt: str | None = None) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    img = Image.new("RGB", size, (200, 60, 40))
    # 左上角畫一塊藍色，用來檢查方向有沒有轉對
    img.paste((0, 0, 255), (0, 0, size[0] // 4, size[1] // 4))
    img.save(path, format=fmt, exif=make_exif(orientation))
    return path


def make_video(path: Path, size="640x360", seconds=2, vcodec="libx264", audio=True) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [find_ffmpeg(), "-loglevel", "error", "-y",
           "-f", "lavfi", "-i", f"testsrc=size={size}:rate=25:duration={seconds}"]
    if audio:
        cmd += ["-f", "lavfi", "-i", f"sine=duration={seconds}", "-c:a", "aac"]
    cmd += ["-c:v", vcodec, "-pix_fmt", "yuv420p", str(path)]
    subprocess.run(cmd, check=True)
    return path


def video_info(path: Path) -> str:
    proc = subprocess.run([find_ffmpeg(), "-hide_banner", "-i", str(path)],
                          capture_output=True, text=True, errors="replace")
    return proc.stderr


@pytest.fixture
def photo(tmp_path):
    return make_photo(tmp_path / "src" / "photo.jpg")


@pytest.fixture
def out_dir(tmp_path):
    return tmp_path / "out"
