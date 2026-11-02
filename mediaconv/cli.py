"""命令列介面。"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime
from pathlib import Path

from tqdm import tqdm

from . import __version__
from .converter import Options, Result, plan, run_job
from .formats import IMAGE_OUTPUT_FORMATS, VIDEO_OUTPUT_FORMATS, normalize_image_format
from .videos import VideoConversionError, find_ffmpeg, parse_resolution

EPILOG = """\
範例：
  mediaconv ~/Pictures/iPhone -o ~/Desktop/converted
      整個資料夾：照片轉 JPG、影片轉 MP4（預設）
  mediaconv photos -o out --image-format png
      照片轉 PNG（反向轉換）
  mediaconv photos -o out --quality 75 --max-size 1920
      JPG 品質 75、最長邊縮到 1920 像素
  mediaconv videos -o out --resolution 720p
      影片轉 720p 的 MP4
  mediaconv clip.mov -o out --video-format gif --start 3 --duration 5
      從第 3 秒開始擷取 5 秒做成 GIF
  mediaconv photos -o share --strip-metadata
      移除 EXIF（含 GPS 位置），適合分享給別人
"""


def _positive_int(value: str) -> int:
    n = int(value)
    if n <= 0:
        raise argparse.ArgumentTypeError("必須是正整數")
    return n


def _quality(value: str) -> int:
    n = int(value)
    if not 1 <= n <= 100:
        raise argparse.ArgumentTypeError("品質必須介於 1 到 100")
    return n


def _resolution(value: str) -> str:
    try:
        parse_resolution(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc))
    return value


def _image_format(value: str) -> str:
    fmt = normalize_image_format(value)
    if fmt not in IMAGE_OUTPUT_FORMATS:
        raise argparse.ArgumentTypeError(
            f"不支援 {value}，可用：{', '.join(IMAGE_OUTPUT_FORMATS)}"
        )
    return fmt


def _non_negative_float(value: str) -> float:
    n = float(value)
    if n < 0:
        raise argparse.ArgumentTypeError("不可為負數")
    return n


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="mediaconv",
        description="照片與影片批次格式轉換。原始檔案不會被修改或覆蓋。",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("inputs", nargs="+", type=Path, metavar="輸入", help="檔案或資料夾（可多個）")
    p.add_argument("-o", "--output", type=Path, default=Path("converted"), metavar="資料夾",
                   help="輸出資料夾（預設：./converted），會保留原本的子資料夾結構")
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")

    g = p.add_argument_group("選擇要轉什麼")
    g.add_argument("--image-format", type=_image_format, default="jpg", metavar="格式",
                   help=f"照片輸出格式：{', '.join(IMAGE_OUTPUT_FORMATS)}（預設 jpg）")
    g.add_argument("--video-format", choices=list(VIDEO_OUTPUT_FORMATS), default="mp4",
                   type=str.lower, metavar="格式",
                   help=f"影片輸出格式：{', '.join(VIDEO_OUTPUT_FORMATS)}（預設 mp4，H.264）")
    g.add_argument("--only", choices=["images", "videos"], help="只處理照片或只處理影片")
    g.add_argument("--no-recursive", action="store_true", help="不要處理子資料夾")

    g = p.add_argument_group("照片選項")
    g.add_argument("-q", "--quality", type=_quality, default=85, metavar="品質",
                   help="JPG/WebP/HEIC/AVIF 品質 1-100（預設 85）")
    g.add_argument("--max-size", type=_positive_int, metavar="像素",
                   help="最長邊不超過幾像素（只縮小、不放大）")
    g.add_argument("--strip-metadata", action="store_true",
                   help="不保留 EXIF（拍攝時間、GPS 等）。預設會保留")

    g = p.add_argument_group("影片選項")
    g.add_argument("-r", "--resolution", type=_resolution, metavar="解析度",
                   help="360p / 480p / 720p / 1080p / 1440p / 4k（只縮小、不放大）")
    g.add_argument("--crf", type=int, metavar="數值",
                   help="畫質：數字越小越清楚、檔案越大（H.264 預設 23，WebM 預設 32）")
    g.add_argument("--preset", default="medium",
                   choices=["ultrafast", "superfast", "veryfast", "faster", "fast",
                            "medium", "slow", "slower", "veryslow"],
                   metavar="速度", help="H.264 編碼速度，越慢檔案越小（預設 medium）")
    g.add_argument("--start", type=_non_negative_float, metavar="秒", help="從第幾秒開始")
    g.add_argument("--duration", type=_non_negative_float, metavar="秒", help="只轉幾秒")
    g.add_argument("--gif-fps", type=_positive_int, default=12, metavar="張數", help="GIF 每秒幾格（預設 12）")
    g.add_argument("--gif-width", type=_positive_int, default=480, metavar="像素", help="GIF 寬度（預設 480）")

    g = p.add_argument_group("其他")
    g.add_argument("--on-exists", choices=["skip", "rename", "overwrite"], default="skip",
                   help="輸出資料夾已有同名檔案時：skip 略過（預設）、rename 另存新名、"
                        "overwrite 覆蓋（只會覆蓋輸出檔，絕不動原檔）")
    g.add_argument("--reencode", action="store_true",
                   help="來源已經是目標格式時也重新壓縮（預設直接複製）")
    g.add_argument("-n", "--dry-run", action="store_true", help="只列出會做什麼，不實際轉換")
    return p


def _check_output_dir(inputs: list[Path], output: Path) -> str | None:
    out = output.resolve()
    for inp in inputs:
        if inp.is_dir() and inp.resolve() == out:
            return f"輸出資料夾不能和輸入資料夾相同：{inp}"
    return None


def _write_error_log(output_dir: Path, result: Result) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    log = output_dir / f"mediaconv-errors-{stamp}.log"
    output_dir.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as f:
        f.write(f"mediaconv {__version__}  {datetime.now():%Y-%m-%d %H:%M:%S}\n")
        f.write(f"失敗 {len(result.failed)} 個檔案：\n\n")
        for job, err in result.failed:
            f.write(f"{job.src}\n    {err}\n")
    return log


def _print_summary(result: Result, interrupted: bool) -> None:
    print()
    print("===== 轉換結果 =====" + ("（已中斷）" if interrupted else ""))
    print(f"  成功：{len(result.converted)}")
    if result.copied:
        print(f"  已是目標格式，直接複製：{len(result.copied)}")
    if result.skipped:
        print(f"  略過：{len(result.skipped)}")
    print(f"  失敗：{len(result.failed)}")
    if result.ignored:
        print(f"  （非照片/影片的檔案 {result.ignored} 個未處理）")
    if result.failed:
        print("\n失敗的檔案：")
        for job, err in result.failed:
            print(f"  ✗ {job.src}\n      {err}")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    err = _check_output_dir(args.inputs, args.output)
    if err:
        print(f"錯誤：{err}", file=sys.stderr)
        return 2

    opts = Options(
        output_dir=args.output,
        image_format=args.image_format,
        video_format=args.video_format,
        only=args.only,
        recursive=not args.no_recursive,
        quality=args.quality,
        max_size=args.max_size,
        keep_metadata=not args.strip_metadata,
        resolution=args.resolution,
        crf=args.crf,
        preset=args.preset,
        gif_fps=args.gif_fps,
        gif_width=args.gif_width,
        start=args.start,
        duration=args.duration,
        on_exists=args.on_exists,
        reencode=args.reencode,
    )

    try:
        jobs, ignored = plan(args.inputs, opts)
    except FileNotFoundError as exc:
        print(f"錯誤：{exc}", file=sys.stderr)
        return 2

    result = Result(ignored=ignored)
    if not jobs:
        print("沒有找到可以轉換的照片或影片。")
        _print_summary(result, False)
        return 0

    if any(j.kind == "video" and j.action == "convert" for j in jobs):
        try:
            find_ffmpeg()
        except VideoConversionError as exc:
            print(f"錯誤：{exc}", file=sys.stderr)
            return 2

    if args.dry_run:
        labels = {"convert": "轉換", "copy": "複製", "skip": "略過"}
        for j in jobs:
            note = f"（{j.reason}）" if j.reason else ""
            print(f"[{labels[j.action]}] {j.src} -> {j.dst}{note}")
        print(f"\n共 {len(jobs)} 個檔案（試跑，沒有實際轉換）")
        return 0

    interrupted = False
    bar = tqdm(total=len(jobs), unit="檔", desc="整體進度", dynamic_ncols=True)
    try:
        for job in jobs:
            bar.set_postfix_str(job.src.name[-40:], refresh=True)
            if job.action == "skip":
                result.skipped.append(job)
                bar.update(1)
                continue

            sub = None
            if job.kind == "video" and job.action == "convert":
                sub = tqdm(total=0, unit="秒", position=1, leave=False,
                           desc=f"  {job.src.name[-30:]}", dynamic_ncols=True,
                           bar_format="{desc}: {percentage:3.0f}%|{bar}| {n:.0f}/{total:.0f} 秒")

            def on_progress(done: float, total: float | None, sub=sub) -> None:
                if sub is None or not total:
                    return
                if sub.total != total:
                    sub.total = total
                sub.n = min(done, total)
                sub.refresh()

            try:
                run_job(job, opts, on_video_progress=on_progress)
            except KeyboardInterrupt:
                raise
            except Exception as exc:
                result.failed.append((job, str(exc) or exc.__class__.__name__))
            else:
                (result.copied if job.action == "copy" else result.converted).append(job)
            finally:
                if sub is not None:
                    sub.close()
            bar.update(1)
    except KeyboardInterrupt:
        interrupted = True
    finally:
        bar.close()

    _print_summary(result, interrupted)
    if result.failed:
        log = _write_error_log(opts.output_dir, result)
        print(f"\n錯誤紀錄已寫入：{log}")
    if interrupted:
        return 130
    return 1 if result.failed else 0


if __name__ == "__main__":
    sys.exit(main())
