"""壓縮模式的測試。"""

import pytest
from PIL import Image, ImageFilter

from mediaconv import compress
from mediaconv.cli import main

from conftest import TAKEN_AT, make_exif, make_video, video_info

import re


def noisy_photo(path, size=(3000, 2000), orientation=1):
    """有雜訊的照片比較接近真實照片的壓縮特性。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    noise = Image.effect_noise(size, 40).filter(ImageFilter.GaussianBlur(1))
    img = Image.merge("RGB", (noise, Image.linear_gradient("L").resize(size), noise))
    img.save(path, quality=95, exif=make_exif(orientation))
    return path


def scanned_pdf(path, pages=2, size=(1240, 1754)):
    """模擬掃描的 PDF：每一頁都是一張大的 JPEG 圖片。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    imgs = [
        Image.merge("RGB", [Image.effect_noise(size, 30).filter(ImageFilter.GaussianBlur(0.8))] * 3)
        for _ in range(pages)
    ]
    imgs[0].save(path, save_all=True, append_images=imgs[1:], resolution=150, quality=95)
    return path


def pdf_pages(path):
    import pikepdf

    with pikepdf.open(path) as pdf:
        return len(pdf.pages)


# ---------- 大小解析 ----------

@pytest.mark.parametrize(
    "text,expected",
    [("25MB", 25 * 1024**2), ("800kb", 800 * 1024), ("1.5G", int(1.5 * 1024**3)), ("10", 10 * 1024**2), ("2 MiB", 2 * 1024**2)],
)
def test_parse_size(text, expected):
    assert compress.parse_size(text) == expected


@pytest.mark.parametrize("text", ["abc", "0", "-5MB", "10TB"])
def test_parse_size_invalid(text):
    with pytest.raises(ValueError):
        compress.parse_size(text)


# ---------- 照片 ----------

@pytest.mark.parametrize("level,longest", [("light", 3000), ("standard", 2048), ("strong", 1280)])
def test_image_levels(tmp_path, level, longest):
    src = noisy_photo(tmp_path / "in.jpg", size=(4000, 3000))
    dst = tmp_path / "out.jpg"
    compress.compress_image(src, dst, level)
    with Image.open(dst) as img:
        assert img.format == "JPEG"
        assert max(img.size) == longest
    assert dst.stat().st_size < src.stat().st_size


def test_image_levels_get_smaller(tmp_path):
    src = noisy_photo(tmp_path / "in.jpg")
    sizes = []
    for level in compress.LEVELS:
        dst = tmp_path / f"{level}.jpg"
        compress.compress_image(src, dst, level)
        sizes.append(dst.stat().st_size)
    assert sizes[0] > sizes[1] > sizes[2]


def test_image_keeps_exif_and_orientation(tmp_path):
    src = noisy_photo(tmp_path / "in.jpg", size=(3000, 2000), orientation=6)
    dst = tmp_path / "out.jpg"
    compress.compress_image(src, dst, "standard")
    with Image.open(dst) as img:
        exif = img.getexif()
        assert img.size == (1365, 2048)  # 轉正後變直的
        assert exif.get(0x0112) == 1
        assert exif.get_ifd(0x8769).get(0x9003) == TAKEN_AT
        assert len(exif.get_ifd(0x8825)) > 0


def test_image_strip_metadata(tmp_path):
    src = noisy_photo(tmp_path / "in.jpg")
    dst = tmp_path / "out.jpg"
    compress.compress_image(src, dst, "standard", keep_metadata=False)
    with Image.open(dst) as img:
        assert len(img.getexif()) == 0


@pytest.mark.parametrize("target_kb", [600, 150, 40])
def test_image_target_size(tmp_path, target_kb):
    src = noisy_photo(tmp_path / "in.jpg")
    dst = tmp_path / "out.jpg"
    notes = compress.compress_image(src, dst, target_size=target_kb * 1024)
    assert dst.stat().st_size <= target_kb * 1024
    if target_kb == 40:
        assert any("縮小" in n for n in notes)


def test_image_generous_target_still_applies_level(tmp_path):
    src = noisy_photo(tmp_path / "in.jpg", size=(4000, 3000))
    dst = tmp_path / "out.jpg"
    compress.compress_image(src, dst, "standard", target_size=100 * 1024**2)
    with Image.open(dst) as img:
        assert max(img.size) == 2048


# ---------- 影片 ----------

def dims(path):
    m = re.search(r"Video: .*?, (\d{2,5})x(\d{2,5})", video_info(path))
    return int(m.group(1)), int(m.group(2))


def test_video_standard(tmp_path):
    src = make_video(tmp_path / "in.mov", size="1920x1080", seconds=2)
    dst = tmp_path / "out.mp4"
    compress.compress_video(src, dst, "standard")
    info = video_info(dst)
    assert "Video: h264" in info and "Audio: aac" in info
    assert dims(dst) == (1280, 720)


def test_video_strong_portrait(tmp_path):
    src = make_video(tmp_path / "in.mov", size="1080x1920", seconds=1)
    dst = tmp_path / "out.mp4"
    compress.compress_video(src, dst, "strong")
    assert dims(dst) == (480, 854)


def test_video_target_size(tmp_path):
    src = tmp_path / "in.mov"
    import subprocess

    from mediaconv.videos import find_ffmpeg

    # 高位元率、有雜訊的影片，接近手機拍的
    subprocess.run([find_ffmpeg(), "-loglevel", "error", "-y", "-f", "lavfi",
                    "-i", "testsrc2=size=1920x1080:rate=30:duration=4,noise=alls=20:allf=t",
                    "-f", "lavfi", "-i", "sine=duration=4", "-c:v", "libx264", "-crf", "18",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", str(src)], check=True)
    target = 600 * 1024
    dst = tmp_path / "out.mp4"
    compress.compress_video(src, dst, target_size=target)
    assert dst.stat().st_size <= target
    assert "Video: h264" in video_info(dst)


def test_video_target_too_small(tmp_path):
    src = make_video(tmp_path / "in.mov", seconds=2)
    with pytest.raises(compress.CompressionError, match="目標大小太小"):
        compress.compress_video(src, tmp_path / "out.mp4", target_size=10 * 1024)


# ---------- PDF ----------

@pytest.mark.skipif(not compress.find_ghostscript(), reason="沒有安裝 Ghostscript")
def test_pdf_ghostscript_downsamples_300dpi_scan(tmp_path):
    src = tmp_path / "scan300.pdf"
    img = Image.merge("RGB", [Image.effect_noise((2480, 3508), 30).filter(ImageFilter.GaussianBlur(0.8))] * 3)
    img.save(src, resolution=300, quality=90)
    dst = tmp_path / "out.pdf"
    compress.compress_pdf(src, dst, "standard")
    assert dst.stat().st_size < src.stat().st_size * 0.5
    assert pdf_pages(dst) == 1


@pytest.mark.skipif(not compress.find_ghostscript(), reason="沒有安裝 Ghostscript")
def test_pdf_low_dpi_scan_still_shrinks_with_ghostscript(tmp_path):
    # 150 dpi 的掃描檔 Ghostscript 不會再降解析度，要靠重新壓縮 JPG 品質
    src = scanned_pdf(tmp_path / "scan.pdf")
    dst = tmp_path / "out.pdf"
    compress.compress_pdf(src, dst, "standard")
    assert dst.stat().st_size < src.stat().st_size * 0.7
    assert pdf_pages(dst) == 2


@pytest.mark.parametrize("level", compress.LEVELS)
def test_pdf_pikepdf_fallback(tmp_path, monkeypatch, level):
    monkeypatch.setattr(compress, "find_ghostscript", lambda: None)
    src = scanned_pdf(tmp_path / "scan.pdf")
    dst = tmp_path / "out.pdf"
    compress.compress_pdf(src, dst, level)
    assert dst.stat().st_size < src.stat().st_size * 0.7
    assert pdf_pages(dst) == 2


def test_pdf_target_size_steps_up_levels(tmp_path):
    src = scanned_pdf(tmp_path / "scan.pdf")
    dst = tmp_path / "out.pdf"
    light = tmp_path / "light.pdf"
    compress.compress_pdf(src, light, "light")
    target = int(light.stat().st_size * 0.6)
    notes = compress.compress_pdf(src, dst, "light", target_size=target)
    assert dst.stat().st_size <= target or any("無法" in n for n in notes)
    assert notes


def test_pdf_encrypted(tmp_path, monkeypatch):
    import pikepdf

    monkeypatch.setattr(compress, "find_ghostscript", lambda: None)
    src = scanned_pdf(tmp_path / "plain.pdf", pages=1)
    locked = tmp_path / "locked.pdf"
    with pikepdf.open(src) as pdf:
        pdf.save(locked, encryption=pikepdf.Encryption(owner="o", user="secret"))
    with pytest.raises(compress.CompressionError, match="密碼"):
        compress.compress_pdf(locked, tmp_path / "out.pdf")


# ---------- 命令列 ----------

def test_cli_compress_mixed_folder(tmp_path, capsys):
    src = tmp_path / "docs"
    noisy_photo(src / "photo.jpg")
    scanned_pdf(src / "sub" / "scan.pdf")
    make_video(src / "clip.mov", size="1920x1080", seconds=1)
    (src / "notes.txt").write_text("hi")
    out = tmp_path / "out"

    assert main([str(src), "-o", str(out), "--compress"]) == 0

    assert (out / "photo.jpg").exists()
    assert (out / "sub" / "scan.pdf").exists()
    assert (out / "clip.mp4").exists()
    text = capsys.readouterr().out
    assert "壓縮結果" in text and "總大小" in text and "失敗：0" in text
    assert (out / "sub" / "scan.pdf").stat().st_size < (src / "sub" / "scan.pdf").stat().st_size


def test_cli_keeps_original_when_not_smaller(tmp_path, capsys):
    # 單色小圖存成 PNG 非常小，壓縮成 JPG 反而變大 -> 保留原本的 PNG（副檔名也不變）
    src = tmp_path / "in"
    src.mkdir()
    Image.new("RGB", (64, 64), (10, 20, 30)).save(src / "tiny.png")
    out = tmp_path / "out"
    main([str(src), "-o", str(out), "--compress", "--level", "light"])
    assert (out / "tiny.png").exists()
    assert not (out / "tiny.jpg").exists()
    assert (out / "tiny.png").read_bytes() == (src / "tiny.png").read_bytes()
    assert "保留原檔：1" in capsys.readouterr().out


def test_cli_only_pdfs_and_target_size(tmp_path):
    src = tmp_path / "in"
    noisy_photo(src / "photo.jpg")
    scanned_pdf(src / "scan.pdf")
    out = tmp_path / "out"
    main([str(src), "-o", str(out), "--compress", "--only", "pdfs", "--target-size", "5MB"])
    assert [p.name for p in out.iterdir() if p.is_file()] == ["scan.pdf"]


def test_cli_pdf_ignored_without_compress(tmp_path, capsys):
    src = tmp_path / "in"
    scanned_pdf(src / "scan.pdf", pages=1)
    main([str(src), "-o", str(tmp_path / "out")])
    assert "非照片/影片的檔案 1 個" in capsys.readouterr().out


def test_cli_invalid_target_size(tmp_path):
    with pytest.raises(SystemExit):
        main([str(tmp_path), "--compress", "--target-size", "lots"])
