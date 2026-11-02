"""掃描檔案、規劃輸出路徑、執行轉換並統計結果。"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

from .formats import (
    IMAGE_INPUT_EXTS,
    IMAGE_OUTPUT_FORMATS,
    VIDEO_INPUT_EXTS,
    VIDEO_OUTPUT_FORMATS,
    is_same_image_format,
    is_same_video_format,
)
from . import compress, images, videos

PDF_EXTS = {".pdf"}

# 已經是目標格式時，這些影像編碼可以直接複製、不必重新壓縮
_COPYABLE_VCODECS = {"mp4": {"h264"}, "mov": {"h264"}, "mkv": {"h264"}, "webm": {"vp9"}, "gif": {"gif"}}


@dataclass
class Options:
    output_dir: Path
    image_format: str = "jpg"
    video_format: str = "mp4"
    only: str | None = None  # "images" / "videos" / None
    recursive: bool = True
    quality: int = 85
    max_size: int | None = None
    keep_metadata: bool = True
    resolution: str | None = None
    crf: int | None = None
    preset: str = "medium"
    gif_fps: int = 12
    gif_width: int = 480
    start: float | None = None
    duration: float | None = None
    on_exists: str = "skip"  # skip / rename / overwrite
    reencode: bool = False
    # 壓縮模式
    compress: bool = False
    level: str = "standard"  # light / standard / strong
    target_size: int | None = None  # 位元組


@dataclass
class Job:
    src: Path
    dst: Path
    kind: str  # "image" / "video" / "pdf"
    action: str = "convert"  # "convert" / "copy" / "skip"；壓縮後變大時會改成 "kept"
    reason: str = ""
    notes: list[str] = field(default_factory=list)


@dataclass
class Result:
    converted: list[Job] = field(default_factory=list)
    copied: list[Job] = field(default_factory=list)
    kept: list[Job] = field(default_factory=list)  # 壓縮後沒有變小，保留原檔
    skipped: list[Job] = field(default_factory=list)
    failed: list[tuple[Job, str]] = field(default_factory=list)
    ignored: int = 0  # 非照片/影片的檔案數


def classify(path: Path) -> str | None:
    ext = path.suffix.lower()
    if ext == ".gif":
        return "video" if images.is_animated(path) else "image"
    if ext in IMAGE_INPUT_EXTS:
        return "image"
    if ext in VIDEO_INPUT_EXTS:
        return "video"
    if ext in PDF_EXTS:
        return "pdf"
    return None


def _is_relative_to(path: Path, other: Path) -> bool:
    try:
        path.relative_to(other)
        return True
    except ValueError:
        return False


def scan(
    inputs: Iterable[Path], output_dir: Path, recursive: bool = True, include_pdf: bool = False
) -> tuple[list[tuple[Path, Path]], int]:
    """回傳 [(檔案, 相對輸出路徑)] 與被忽略的檔案數。會排除輸出資料夾本身。"""
    out_resolved = output_dir.resolve()
    found: list[tuple[Path, Path]] = []
    ignored = 0
    for inp in inputs:
        inp = Path(inp)
        if inp.is_file():
            candidates = [(inp, Path(inp.name))]
        elif inp.is_dir():
            pattern = "**/*" if recursive else "*"
            candidates = []
            for p in sorted(inp.glob(pattern)):
                if not p.is_file() or p.name.startswith("."):
                    continue
                if _is_relative_to(p.resolve(), out_resolved):
                    continue
                candidates.append((p, p.relative_to(inp)))
        else:
            raise FileNotFoundError(f"找不到：{inp}")
        for path, rel in candidates:
            ext = path.suffix.lower()
            if ext in IMAGE_INPUT_EXTS or ext in VIDEO_INPUT_EXTS or (include_pdf and ext in PDF_EXTS):
                found.append((path, rel))
            else:
                ignored += 1
    return found, ignored


def _unique_path(path: Path, taken: set[Path]) -> Path:
    n = 1
    candidate = path
    while candidate in taken or candidate.exists():
        candidate = path.with_name(f"{path.stem}_{n}{path.suffix}")
        n += 1
    return candidate


def plan(inputs: Iterable[Path], opts: Options) -> tuple[list[Job], int]:
    files, ignored = scan(inputs, opts.output_dir, opts.recursive, include_pdf=opts.compress)
    jobs: list[Job] = []
    taken: set[Path] = set()
    out_dir = opts.output_dir

    for src, rel in files:
        kind = classify(src)
        if kind is None:
            ignored += 1
            continue
        if opts.only == "images" and kind != "image":
            continue
        if opts.only == "videos" and kind != "video":
            continue
        if opts.only == "pdfs" and kind != "pdf":
            continue

        if opts.compress:
            ext = {"image": ".jpg", "video": ".mp4", "pdf": ".pdf"}[kind]
        elif kind == "image":
            ext = IMAGE_OUTPUT_FORMATS[opts.image_format][1]
        else:
            ext = VIDEO_OUTPUT_FORMATS[opts.video_format]
        dst = out_dir / rel.with_suffix(ext)

        # 同一次轉換中不同來源撞名（例如 a.heic 和 a.png 都要變成 a.jpg）
        if dst in taken:
            dst = dst.with_name(f"{rel.stem}_{src.suffix.lstrip('.').lower()}{ext}")
            dst = _unique_path(dst, taken)

        job = Job(src=src, dst=dst, kind=kind)

        if dst.resolve() == src.resolve():
            job.action, job.reason = "skip", "輸出路徑與來源相同"
        elif dst.exists():
            if opts.on_exists == "skip":
                job.action, job.reason = "skip", "輸出檔已存在"
            elif opts.on_exists == "rename":
                job.dst = _unique_path(dst, taken)

        if job.action == "convert" and not opts.compress and not opts.reencode and _can_copy(job, opts):
            job.action = "copy"

        taken.add(job.dst)
        jobs.append(job)
    return jobs, ignored


def _can_copy(job: Job, opts: Options) -> bool:
    """來源已經是目標格式、又不需要調整時，直接複製最快也不損失畫質。"""
    if job.kind == "image":
        return (
            is_same_image_format(job.src.suffix, opts.image_format)
            and not opts.max_size
            and opts.keep_metadata
        )
    if opts.resolution or opts.start or opts.duration:
        return False
    if not is_same_video_format(job.src.suffix, opts.video_format):
        return False
    if opts.video_format == "gif":
        return True
    vcodec = videos.probe(job.src).get("vcodec")
    return vcodec in _COPYABLE_VCODECS[opts.video_format]


def _temp_path(dst: Path) -> Path:
    return dst.with_name(f".{dst.stem}.mediaconv-tmp{dst.suffix}")


def run_job(
    job: Job,
    opts: Options,
    on_video_progress: Callable[[float, float | None], None] | None = None,
) -> None:
    """執行單一工作。失敗時丟出例外，且不會留下不完整的輸出檔。"""
    job.dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = _temp_path(job.dst)
    try:
        if opts.compress:
            _run_compress(job, opts, tmp, on_video_progress)
            if tmp.stat().st_size >= job.src.stat().st_size:
                # 壓縮後沒有比較小，直接保留原檔（副檔名也維持原本的）
                tmp.unlink()
                job.action = "kept"
                job.notes = ["原檔已經很小，保留原檔"]
                kept_dst = job.dst.with_suffix(job.src.suffix)
                if kept_dst != job.dst and kept_dst.exists() and opts.on_exists != "overwrite":
                    kept_dst = _unique_path(kept_dst, set())
                job.dst = kept_dst
                tmp = _temp_path(job.dst)
                shutil.copy2(job.src, tmp)
        elif job.action == "copy":
            # 直接複製前先確認檔案沒壞
            if job.kind == "image":
                images.verify_image(job.src)
            shutil.copy2(job.src, tmp)
        elif job.kind == "image":
            images.convert_image(
                job.src,
                tmp,
                opts.image_format,
                quality=opts.quality,
                max_size=opts.max_size,
                keep_metadata=opts.keep_metadata,
            )
        else:
            videos.convert_video(
                job.src,
                tmp,
                opts.video_format,
                on_progress=on_video_progress,
                resolution=opts.resolution,
                crf=opts.crf,
                preset=opts.preset,
                gif_fps=opts.gif_fps,
                gif_width=opts.gif_width,
                start=opts.start,
                duration=opts.duration,
            )
        os.replace(tmp, job.dst)
        if job.action not in ("copy", "kept"):
            _copy_times(job.src, job.dst)
    finally:
        if tmp.exists():
            tmp.unlink()


def _copy_times(src: Path, dst: Path) -> None:
    """讓輸出檔的修改時間跟原檔一樣，方便在相簿/檔案總管照時間排序。"""
    try:
        st = src.stat()
        os.utime(dst, (st.st_atime, st.st_mtime))
    except OSError:
        pass


def _run_compress(job: Job, opts: Options, tmp: Path, on_video_progress) -> None:
    if job.kind == "image":
        job.notes = compress.compress_image(
            job.src, tmp, opts.level, opts.target_size, keep_metadata=opts.keep_metadata
        )
    elif job.kind == "video":
        job.notes = compress.compress_video(
            job.src, tmp, opts.level, opts.target_size,
            keep_metadata=opts.keep_metadata, on_progress=on_video_progress,
        )
    else:
        job.notes = compress.compress_pdf(job.src, tmp, opts.level, opts.target_size)
