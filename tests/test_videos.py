import re

import pytest

from mediaconv.videos import (
    VideoConversionError,
    convert_video,
    parse_resolution,
    probe,
)

from conftest import make_video, video_info


def dimensions(path):
    m = re.search(r"Video: .*?, (\d{2,5})x(\d{2,5})", video_info(path))
    return int(m.group(1)), int(m.group(2))


@pytest.mark.parametrize(
    "ext,vcodec",
    [(".mov", "libx264"), (".avi", "mpeg4"), (".mkv", "libx264"), (".webm", "libvpx-vp9")],
)
def test_common_containers_to_mp4_h264(tmp_path, ext, vcodec):
    src = make_video(tmp_path / f"in{ext}", vcodec=vcodec, audio=ext != ".webm")
    dst = tmp_path / "out.mp4"
    convert_video(src, dst, "mp4")
    info = video_info(dst)
    assert "Video: h264" in info
    assert "yuv420p" in info


def test_audio_kept(tmp_path):
    src = make_video(tmp_path / "in.mov")
    dst = tmp_path / "out.mp4"
    convert_video(src, dst, "mp4")
    assert "Audio: aac" in video_info(dst)


@pytest.mark.parametrize("fmt,codec", [("mov", "h264"), ("mkv", "h264"), ("webm", "vp9")])
def test_reverse_conversions(tmp_path, fmt, codec):
    src = make_video(tmp_path / "in.mp4", seconds=1)
    dst = tmp_path / f"out.{fmt}"
    convert_video(src, dst, fmt)
    assert f"Video: {codec}" in video_info(dst)


def test_resolution_landscape(tmp_path):
    src = make_video(tmp_path / "in.mov", size="1920x1080", seconds=1)
    dst = tmp_path / "out.mp4"
    convert_video(src, dst, "mp4", resolution="720p")
    assert dimensions(dst) == (1280, 720)


def test_resolution_portrait(tmp_path):
    src = make_video(tmp_path / "in.mov", size="1080x1920", seconds=1)
    dst = tmp_path / "out.mp4"
    convert_video(src, dst, "mp4", resolution="720p")
    assert dimensions(dst) == (720, 1280)


def test_resolution_never_upscales(tmp_path):
    src = make_video(tmp_path / "in.mov", size="640x360", seconds=1)
    dst = tmp_path / "out.mp4"
    convert_video(src, dst, "mp4", resolution="1080p")
    assert dimensions(dst) == (640, 360)


def test_odd_dimensions_made_even(tmp_path):
    src = make_video(tmp_path / "in.avi", size="321x241", seconds=1, vcodec="mpeg4")
    dst = tmp_path / "out.mp4"
    convert_video(src, dst, "mp4")
    w, h = dimensions(dst)
    assert w % 2 == 0 and h % 2 == 0


def test_gif_with_trim(tmp_path):
    src = make_video(tmp_path / "in.mov", size="1280x720", seconds=4)
    dst = tmp_path / "out.gif"
    convert_video(src, dst, "gif", start=1, duration=2, gif_width=320, gif_fps=10)
    assert dst.read_bytes()[:6] in (b"GIF89a", b"GIF87a")
    assert dimensions(dst) == (320, 180)
    assert 1.5 <= probe(dst)["duration"] <= 2.5


def test_progress_callback(tmp_path):
    src = make_video(tmp_path / "in.mov", seconds=2)
    calls = []
    convert_video(src, tmp_path / "out.mp4", "mp4", on_progress=lambda d, t: calls.append((d, t)))
    assert calls
    done, total = calls[-1]
    assert total == pytest.approx(2.0, abs=0.2)
    assert done == pytest.approx(total)


def test_broken_video_raises(tmp_path):
    src = tmp_path / "broken.mp4"
    src.write_bytes(b"\x00" * 1000)
    with pytest.raises(VideoConversionError):
        convert_video(src, tmp_path / "out.mp4", "mp4")


@pytest.mark.parametrize(
    "value,expected",
    [("720p", (1280, 720)), ("1080", (1920, 1080)), ("4K", (3840, 2160)), ("2160p", (3840, 2160))],
)
def test_parse_resolution(value, expected):
    assert parse_resolution(value) == expected


def test_parse_resolution_invalid():
    with pytest.raises(ValueError):
        parse_resolution("big")
