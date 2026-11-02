"""影片轉換（呼叫 ffmpeg）。"""

from __future__ import annotations

import re
import shutil
import subprocess
import threading
from pathlib import Path
from typing import Callable

RESOLUTIONS = {
    # 名稱 -> (長邊, 短邊)
    "360p": (640, 360),
    "480p": (854, 480),
    "720p": (1280, 720),
    "1080p": (1920, 1080),
    "1440p": (2560, 1440),
    "2160p": (3840, 2160),
    "4k": (3840, 2160),
}

_DURATION_RE = re.compile(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)")

# 影片容器格式（交給 ffmpeg -f）
_MUXERS = {"mp4": "mp4", "mov": "mov", "mkv": "matroska", "webm": "webm", "gif": "gif"}


class VideoConversionError(Exception):
    pass


_ffmpeg_cache: str | None = None


def find_ffmpeg() -> str:
    """優先用系統的 ffmpeg，找不到就用 imageio-ffmpeg 內附的版本。"""
    global _ffmpeg_cache
    if _ffmpeg_cache:
        return _ffmpeg_cache
    path = shutil.which("ffmpeg")
    if not path:
        try:
            import imageio_ffmpeg

            path = imageio_ffmpeg.get_ffmpeg_exe()
        except Exception:
            path = None
    if not path:
        raise VideoConversionError(
            "找不到 ffmpeg。請安裝 ffmpeg（Mac: brew install ffmpeg；"
            "Windows: winget install ffmpeg），或 pip install imageio-ffmpeg"
        )
    _ffmpeg_cache = path
    return path


def parse_resolution(value: str) -> tuple[int, int]:
    """'720p' / '1080' / '4k' -> (長邊, 短邊)。"""
    key = value.strip().lower()
    if key in RESOLUTIONS:
        return RESOLUTIONS[key]
    key = key.rstrip("p")
    if key.isdigit() and int(key) >= 16:
        short = int(key)
        return (round(short * 16 / 9), short)
    raise ValueError(f"看不懂的解析度：{value}（例如 720p、1080p、4k）")


_VCODEC_RE = re.compile(r"Stream #\S+.*?: Video: (\w+)")


def probe(src: Path) -> dict:
    """讀取影片長度（秒）與影像編碼，例如 {"duration": 12.3, "vcodec": "h264"}。"""
    proc = subprocess.run(
        [find_ffmpeg(), "-hide_banner", "-i", str(src)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    info: dict = {"duration": None, "vcodec": None}
    m = _DURATION_RE.search(proc.stderr)
    if m:
        h, mnt, sec = m.groups()
        info["duration"] = int(h) * 3600 + int(mnt) * 60 + float(sec)
    m = _VCODEC_RE.search(proc.stderr)
    if m:
        info["vcodec"] = m.group(1)
    return info


def _scale_filter(resolution: str | None) -> str:
    """產生縮放濾鏡：只縮小不放大、維持比例、寬高為偶數（H.264 需要）。"""
    if not resolution:
        return "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    long_side, short_side = parse_resolution(resolution)
    # 橫向影片限制成 長x短，直向影片限制成 短x長
    w = f"'if(gte(iw,ih),min(iw,{long_side}),min(iw,{short_side}))'"
    h = f"'if(gte(iw,ih),min(ih,{short_side}),min(ih,{long_side}))'"
    return f"scale={w}:{h}:force_original_aspect_ratio=decrease:force_divisible_by=2"


def build_command(
    src: Path,
    dst: Path,
    fmt: str,
    resolution: str | None = None,
    crf: int | None = None,
    preset: str = "medium",
    gif_fps: int = 12,
    gif_width: int = 480,
    start: float | None = None,
    duration: float | None = None,
) -> list[str]:
    if fmt not in _MUXERS:
        raise VideoConversionError(f"不支援的影片輸出格式：{fmt}")

    cmd = [find_ffmpeg(), "-hide_banner", "-nostdin", "-y", "-loglevel", "error"]
    if start:
        cmd += ["-ss", str(start)]
    cmd += ["-i", str(src)]
    if duration:
        cmd += ["-t", str(duration)]

    if fmt == "gif":
        width = f"'min(iw,{gif_width})'"
        vf = (
            f"fps={gif_fps},scale={width}:-2:flags=lanczos,"
            "split[a][b];[a]palettegen=stats_mode=diff[p];"
            "[b][p]paletteuse=dither=bayer:bayer_scale=5"
        )
        cmd += ["-vf", vf, "-an", "-loop", "0"]
    elif fmt == "webm":
        cmd += [
            "-map", "0:v:0", "-map", "0:a?", "-sn", "-dn",
            "-vf", _scale_filter(resolution),
            "-c:v", "libvpx-vp9", "-crf", str(crf if crf is not None else 32), "-b:v", "0",
            "-row-mt", "1",
            "-c:a", "libopus", "-b:a", "128k",
            "-map_metadata", "0",
        ]
    else:  # mp4 / mov / mkv：H.264 + AAC，相容性最好
        cmd += [
            "-map", "0:v:0", "-map", "0:a?", "-sn", "-dn",
            "-vf", _scale_filter(resolution),
            "-c:v", "libx264", "-crf", str(crf if crf is not None else 23),
            "-preset", preset, "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "160k",
            "-map_metadata", "0",
        ]
        if fmt in ("mp4", "mov"):
            # faststart：網頁/手機可邊下載邊播；use_metadata_tags：保留拍攝時間、位置等
            cmd += ["-movflags", "+faststart+use_metadata_tags"]

    cmd += ["-f", _MUXERS[fmt], "-progress", "pipe:1", "-nostats", str(dst)]
    return cmd


def convert_video(
    src: Path,
    dst: Path,
    fmt: str,
    on_progress: Callable[[float, float | None], None] | None = None,
    **options,
) -> None:
    """轉換影片。on_progress(已處理秒數, 總秒數) 會在轉換過程中被呼叫。"""
    total = probe(src)["duration"]
    if total is not None:
        start = options.get("start") or 0
        total = max(total - start, 0)
        if options.get("duration"):
            total = min(total, options["duration"])

    cmd = build_command(src, dst, fmt, **options)
    run_ffmpeg(cmd, dst, total, on_progress)


def run_ffmpeg(
    cmd: list[str],
    dst: Path,
    total: float | None,
    on_progress: Callable[[float, float | None], None] | None = None,
) -> None:
    """執行 ffmpeg 並回報進度；失敗時丟出 VideoConversionError。"""
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    # stderr 在背景收集，避免緩衝區塞滿造成卡住
    err_chunks: list[str] = []
    reader = threading.Thread(target=lambda: err_chunks.append(proc.stderr.read()), daemon=True)
    reader.start()

    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            key, _, value = line.strip().partition("=")
            if key == "out_time_us" and on_progress and value.isdigit():
                on_progress(int(value) / 1_000_000, total)
        proc.wait()
    except BaseException:
        proc.kill()
        proc.wait()
        raise
    finally:
        reader.join(timeout=5)

    if proc.returncode != 0:
        msg = "".join(err_chunks).strip().splitlines()
        detail = " / ".join(msg[-3:]) if msg else f"ffmpeg 結束代碼 {proc.returncode}"
        raise VideoConversionError(detail)
    if not dst.exists() or dst.stat().st_size == 0:
        raise VideoConversionError("ffmpeg 沒有產生輸出（來源可能沒有影像軌）")
    if on_progress and total:
        on_progress(total, total)
