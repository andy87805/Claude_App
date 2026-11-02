import pytest
from PIL import Image

from mediaconv.images import ImageConversionError, convert_image
from mediaconv.formats import IMAGE_OUTPUT_FORMATS

from conftest import GPS, TAKEN_AT, make_photo


def read_exif(path):
    with Image.open(path) as img:
        exif = img.getexif()
        return exif, exif.get_ifd(0x8769), exif.get_ifd(0x8825)


@pytest.mark.parametrize("fmt", list(IMAGE_OUTPUT_FORMATS))
def test_convert_to_every_format(tmp_path, photo, fmt):
    pil_format, ext = IMAGE_OUTPUT_FORMATS[fmt]
    dst = tmp_path / f"out{ext}"
    convert_image(photo, dst, fmt)
    with Image.open(dst) as img:
        assert img.format == pil_format
        assert img.size == (400, 300)


@pytest.mark.parametrize("fmt", ["jpg", "png", "webp", "heic", "avif", "tiff"])
def test_exif_preserved(tmp_path, photo, fmt):
    dst = tmp_path / f"out{IMAGE_OUTPUT_FORMATS[fmt][1]}"
    convert_image(photo, dst, fmt)
    exif, exif_ifd, gps = read_exif(dst)
    assert exif.get(0x010F) == "TestCam"
    assert exif_ifd.get(0x9003) == TAKEN_AT
    assert gps.get(1) == GPS[1] and gps.get(3) == GPS[3]
    assert tuple(float(v) for v in gps.get(2)) == GPS[2]


@pytest.mark.parametrize("src_ext", [".heic", ".png", ".webp"])
def test_common_sources_to_jpg_keep_exif(tmp_path, src_ext):
    src = make_photo(tmp_path / f"in{src_ext}")
    dst = tmp_path / "out.jpg"
    convert_image(src, dst, "jpg")
    _, exif_ifd, gps = read_exif(dst)
    assert exif_ifd.get(0x9003) == TAKEN_AT
    assert gps.get(1) == "N"


def test_strip_metadata(tmp_path, photo):
    dst = tmp_path / "out.jpg"
    convert_image(photo, dst, "jpg", keep_metadata=False)
    exif, _, gps = read_exif(dst)
    assert len(exif) == 0 and len(gps) == 0


def test_orientation_applied_and_reset(tmp_path):
    # Orientation 6 = 需要順時針轉 90 度才是正的
    src = make_photo(tmp_path / "rot.jpg", size=(400, 300), orientation=6)
    dst = tmp_path / "out.jpg"
    convert_image(src, dst, "jpg")
    with Image.open(dst) as img:
        assert img.size == (300, 400)
        assert img.getexif().get(0x0112) == 1
        # 原本左上角的藍色轉 90 度後會到右上角
        r, g, b = img.convert("RGB").getpixel((img.width - 10, 10))
        assert b > 150 and r < 100


def test_max_size_downscales_only(tmp_path, photo):
    dst = tmp_path / "small.jpg"
    convert_image(photo, dst, "jpg", max_size=200)
    with Image.open(dst) as img:
        assert img.size == (200, 150)

    dst2 = tmp_path / "same.jpg"
    convert_image(photo, dst2, "jpg", max_size=5000)
    with Image.open(dst2) as img:
        assert img.size == (400, 300)


def test_quality_affects_size(tmp_path):
    src = tmp_path / "noise.png"
    Image.effect_noise((300, 300), 60).convert("RGB").save(src)
    lo, hi = tmp_path / "lo.jpg", tmp_path / "hi.jpg"
    convert_image(src, lo, "jpg", quality=30)
    convert_image(src, hi, "jpg", quality=95)
    assert lo.stat().st_size < hi.stat().st_size


def test_transparent_png_to_jpg_gets_white_background(tmp_path):
    src = tmp_path / "alpha.png"
    Image.new("RGBA", (20, 20), (0, 0, 0, 0)).save(src)
    dst = tmp_path / "out.jpg"
    convert_image(src, dst, "jpg")
    with Image.open(dst) as img:
        assert img.mode == "RGB"
        assert all(c > 245 for c in img.getpixel((10, 10)))


def test_transparency_kept_for_png_and_webp(tmp_path):
    src = tmp_path / "alpha.png"
    Image.new("RGBA", (20, 20), (0, 0, 255, 100)).save(src)
    for fmt in ("png", "webp"):
        dst = tmp_path / f"out.{fmt}"
        convert_image(src, dst, fmt)
        with Image.open(dst) as img:
            assert img.mode == "RGBA"


def test_palette_and_grayscale_inputs(tmp_path):
    p = tmp_path / "p.gif"
    Image.new("RGB", (10, 10), (10, 200, 10)).convert("P").save(p)
    g = tmp_path / "g16.png"
    Image.new("I;16", (10, 10), 30000).save(g)
    for src in (p, g):
        dst = tmp_path / f"{src.stem}.jpg"
        convert_image(src, dst, "jpg")
        assert dst.exists()


def test_broken_file_raises(tmp_path):
    src = tmp_path / "broken.jpg"
    src.write_bytes(b"definitely not a jpeg")
    with pytest.raises(ImageConversionError):
        convert_image(src, tmp_path / "out.png", "png")
