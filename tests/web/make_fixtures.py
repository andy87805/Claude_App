"""產生網頁版測試用的照片與影片：python make_fixtures.py <輸出資料夾>"""

import subprocess
import sys
from pathlib import Path

from PIL import Image
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
