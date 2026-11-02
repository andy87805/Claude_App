"""讀出照片／影片的資訊並印成 JSON，給網頁版測試驗證輸出用。"""

import json
import re
import subprocess
import sys

from PIL import Image
from pillow_heif import register_heif_opener

register_heif_opener()


def image_info(path):
    with Image.open(path) as img:
        exif = img.getexif()
        gps = exif.get_ifd(0x8825)
        rgb = img.convert("RGB")
        return {
            "kind": "image",
            "format": img.format,
            "size": list(img.size),
            "orientation": exif.get(0x0112),
            "make": exif.get(0x010F),
            "taken": exif.get_ifd(0x8769).get(0x9003),
            "gps": bool(len(gps)),
            "topLeft": list(rgb.getpixel((5, 5))),
            "topRight": list(rgb.getpixel((img.width - 6, 5))),
            "center": list(rgb.getpixel((img.width // 2, img.height // 2))),
        }


def video_info(path):
    err = subprocess.run(["ffmpeg", "-hide_banner", "-i", path], capture_output=True, text=True).stderr
    v = re.search(r"Video: (\w+).*?, (\d{2,5})x(\d{2,5})", err)
    a = re.search(r"Audio: (\w+)", err)
    d = re.search(r"Duration: (\d+):(\d+):([\d.]+)", err)
    return {
        "kind": "video",
        "vcodec": v and v.group(1),
        "size": v and [int(v.group(2)), int(v.group(3))],
        "acodec": a and a.group(1),
        "duration": d and int(d.group(1)) * 3600 + int(d.group(2)) * 60 + float(d.group(3)),
        "creation_time": "creation_time   : 2024-05-01" in err,
    }


if __name__ == "__main__":
    path = sys.argv[1]
    try:
        info = image_info(path)
        if info["format"] == "GIF":
            info.update({k: v for k, v in video_info(path).items() if k in ("duration",)})
    except Exception:
        info = video_info(path)
    print(json.dumps(info))
