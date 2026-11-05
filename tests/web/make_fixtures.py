"""產生網頁版測試用的照片與影片：python make_fixtures.py <輸出資料夾>"""

import subprocess
import sys
import zlib
from pathlib import Path

import pikepdf
from PIL import Image, ImageFilter
from pikepdf import Dictionary, Name
from pillow_heif import register_heif_opener

register_heif_opener()

TAKEN_AT = "2024:05:01 10:20:30"


def exif_bytes(orientation=1):
    exif = Image.Exif()
    exif[0x0112] = orientation
    exif[0x010F] = "TestCam"
    exif[0x0110] = "Model X"
    exif.get_ifd(0x8769)[0x9003] = TAKEN_AT
    exif.get_ifd(0x8825).update({1: "N", 2: (25.0, 2.0, 30.0), 3: "E", 4: (121.0, 33.0, 15.0)})
    return exif.tobytes()


def photo(size=(400, 300)):
    img = Image.new("RGB", size, (200, 60, 40))
    img.paste((0, 0, 255), (0, 0, size[0] // 4, size[1] // 4))  # 左上角藍色，用來檢查方向
    return img


def noisy(size):
    n = Image.effect_noise(size, 40).filter(ImageFilter.GaussianBlur(1))
    return Image.merge("RGB", (n, Image.linear_gradient("L").resize(size), n))


def image_pdf(path, img, dpi, flate=False):
    """一頁一張圖的 PDF；flate=True 時用無損壓縮加 PNG 預測（螢幕截圖轉 PDF 常見的格式）。"""
    pdf = pikepdf.new()
    w, h = img.size
    if flate:
        raw = img.tobytes()
        row = w * 3
        data = bytearray()
        for y in range(h):
            line = raw[y * row:(y + 1) * row]
            data.append(1)  # PNG Sub 濾波
            data.extend((line[i] - (line[i - 3] if i >= 3 else 0)) & 255 for i in range(row))
        stream = pikepdf.Stream(pdf, zlib.compress(bytes(data)))
        stream.DecodeParms = Dictionary(Predictor=15, Colors=3, Columns=w, BitsPerComponent=8)
        stream.Filter = Name.FlateDecode
    else:
        import io
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=92)
        stream = pikepdf.Stream(pdf, buf.getvalue())
        stream.Filter = Name.DCTDecode
    stream.Type, stream.Subtype = Name.XObject, Name.Image
    stream.Width, stream.Height = w, h
    stream.ColorSpace, stream.BitsPerComponent = Name.DeviceRGB, 8
    pw, ph = w * 72 / dpi, h * 72 / dpi
    pdf.add_blank_page(page_size=(pw, ph))
    page = pdf.pages[0]
    page.Resources = Dictionary(XObject=Dictionary(Im0=stream))
    page.Contents = pdf.make_stream(f"q {pw:.2f} 0 0 {ph:.2f} 0 0 cm /Im0 Do Q".encode())
    pdf.save(path)


def text_pdf(path, pages=2):
    pdf = pikepdf.new()
    font = pdf.make_indirect(Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica))
    for n in range(pages):
        pdf.add_blank_page(page_size=(595, 842))
        page = pdf.pages[n]
        page.Resources = Dictionary(Font=Dictionary(F1=font))
        lines = "".join(f"BT /F1 11 Tf 50 {800 - i * 14} Td (Line {i} of a plain text document) Tj ET " for i in range(50))
        page.Contents = pdf.make_stream(lines.encode())
    pdf.save(path)


def apple(path):
    """桌上的一顆蘋果：給去背測試用（主體在中間，背景是天空漸層和桌面）。"""
    from PIL import ImageDraw

    w, h = 1200, 900
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        d.line([(0, y), (w, y)], fill=(120 + y // 10, 170, 210 - y // 12))
    img = Image.blend(img, Image.effect_noise((w, h), 25).convert("RGB"), 0.15)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 650, w, h], fill=(150, 110, 80))
    d.ellipse([430, 280, 770, 620], fill=(200, 30, 40))
    d.ellipse([500, 330, 580, 410], fill=(240, 120, 120))
    d.rectangle([592, 220, 608, 300], fill=(90, 60, 30))
    d.ellipse([608, 215, 700, 265], fill=(60, 150, 50))
    img.filter(ImageFilter.GaussianBlur(0.8)).save(path, quality=92, exif=exif_bytes(1))


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *args], check=True)


def main(out: Path):
    out.mkdir(parents=True, exist_ok=True)
    photo().save(out / "rotated.jpg", exif=exif_bytes(6), quality=95)
    photo().save(out / "photo.heic", exif=exif_bytes(1))
    photo().save(out / "photo.png", exif=exif_bytes(1))
    photo().save(out / "photo.webp", exif=exif_bytes(1))
    photo((3000, 2000)).save(out / "large.jpg", exif=exif_bytes(1))
    Image.new("RGBA", (40, 40), (0, 0, 0, 0)).save(out / "alpha.png")
    (out / "broken.jpg").write_bytes(b"this is not an image")

    noisy((3000, 2000)).save(out / "noisy.jpg", quality=95, exif=exif_bytes(1))
    apple(out / "apple.jpg")

    image_pdf(out / "scan.pdf", noisy((1654, 2339)), dpi=200)
    image_pdf(out / "flate.pdf", noisy((800, 1100)), dpi=150, flate=True)
    text_pdf(out / "text.pdf")
    with pikepdf.open(out / "scan.pdf") as pdf:
        pdf.save(out / "locked.pdf", encryption=pikepdf.Encryption(owner="o", user="secret"))

    ffmpeg("-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=2,noise=alls=12:allf=t",
           "-f", "lavfi", "-i", "sine=duration=2", "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-b:a", "256k", str(out / "hd.mov"))

    src = ["-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30:duration=3",
           "-f", "lavfi", "-i", "sine=frequency=440:duration=3"]
    ffmpeg(*src, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
           "-metadata", "creation_time=2024-05-01T10:20:30Z", str(out / "clip.mov"))
    ffmpeg(*src, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "libopus", str(out / "opus.mkv"))
    ffmpeg(*src, "-c:v", "libvpx-vp9", "-b:v", "500k", "-c:a", "libopus", str(out / "clip.webm"))
    ffmpeg("-f", "lavfi", "-i", "testsrc=size=720x1280:rate=30:duration=2",
           "-c:v", "libx264", "-pix_fmt", "yuv420p", str(out / "portrait.mp4"))
    ffmpeg("-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=1",
           "-c:v", "mpeg4", str(out / "old.avi"))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
