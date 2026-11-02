"""整個命令列流程的測試：批次、子資料夾、不覆蓋原檔、壞檔處理、統計。"""

import hashlib

import pytest
from PIL import Image

from mediaconv.cli import main

from conftest import make_photo, make_video, video_info


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


@pytest.fixture
def library(tmp_path):
    """模擬一個混合照片、影片、壞檔、其他檔案的資料夾。"""
    root = tmp_path / "library"
    make_photo(root / "a.heic")
    make_photo(root / "b.png")
    make_photo(root / "trip" / "c.webp")
    make_photo(root / "trip" / "day2" / "d.jpg")
    make_video(root / "trip" / "clip.mov", seconds=1)
    make_video(root / "old.avi", seconds=1, vcodec="mpeg4")
    (root / "broken.heic").write_bytes(b"garbage")
    (root / "notes.txt").write_text("hello")
    return root


def test_batch_recursive_defaults(library, out_dir, capsys):
    before = {p: sha(p) for p in library.rglob("*") if p.is_file()}

    code = main([str(library), "-o", str(out_dir)])

    assert code == 1  # 有壞檔 -> 結束代碼 1
    assert (out_dir / "a.jpg").exists()
    assert (out_dir / "b.jpg").exists()
    assert (out_dir / "trip" / "c.jpg").exists()
    assert (out_dir / "trip" / "day2" / "d.jpg").exists()  # 已是 JPG，直接複製
    assert "Video: h264" in video_info(out_dir / "trip" / "clip.mp4")
    assert "Video: h264" in video_info(out_dir / "old.mp4")
    assert not (out_dir / "broken.jpg").exists()  # 不留下壞掉的輸出

    out = capsys.readouterr().out
    assert "成功：5" in out
    assert "直接複製：1" in out
    assert "失敗：1" in out
    assert "broken.heic" in out

    logs = list(out_dir.glob("mediaconv-errors-*.log"))
    assert len(logs) == 1 and "broken.heic" in logs[0].read_text(encoding="utf-8")

    # 原始檔完全沒被動到
    after = {p: sha(p) for p in library.rglob("*") if p.is_file()}
    assert before == after
    # 沒有殘留暫存檔
    assert not list(out_dir.rglob("*mediaconv-tmp*"))


def test_no_recursive(library, out_dir):
    main([str(library), "-o", str(out_dir), "--no-recursive", "--only", "images"])
    assert (out_dir / "a.jpg").exists()
    assert not (out_dir / "trip").exists()


def test_only_videos(library, out_dir):
    main([str(library), "-o", str(out_dir), "--only", "videos"])
    files = {p.name for p in out_dir.rglob("*") if p.is_file()}
    assert files == {"clip.mp4", "old.mp4"}


def test_reverse_jpg_to_png(tmp_path, out_dir):
    src = make_photo(tmp_path / "in" / "x.jpg")
    assert main([str(src), "-o", str(out_dir), "--image-format", "png"]) == 0
    with Image.open(out_dir / "x.png") as img:
        assert img.format == "PNG"


def test_quality_and_max_size(tmp_path, out_dir):
    src = make_photo(tmp_path / "in" / "x.png", size=(1000, 500))
    main([str(src), "-o", str(out_dir), "-q", "60", "--max-size", "300"])
    with Image.open(out_dir / "x.jpg") as img:
        assert img.size == (300, 150)


def test_existing_output_is_skipped_by_default(tmp_path, out_dir, capsys):
    src = make_photo(tmp_path / "in" / "x.png")
    out_dir.mkdir()
    (out_dir / "x.jpg").write_bytes(b"keep me")
    assert main([str(src), "-o", str(out_dir)]) == 0
    assert (out_dir / "x.jpg").read_bytes() == b"keep me"
    assert "略過：1" in capsys.readouterr().out


def test_existing_output_rename(tmp_path, out_dir):
    src = make_photo(tmp_path / "in" / "x.png")
    out_dir.mkdir()
    (out_dir / "x.jpg").write_bytes(b"keep me")
    main([str(src), "-o", str(out_dir), "--on-exists", "rename"])
    assert (out_dir / "x.jpg").read_bytes() == b"keep me"
    assert (out_dir / "x_1.jpg").exists()


def test_existing_output_overwrite(tmp_path, out_dir):
    src = make_photo(tmp_path / "in" / "x.png")
    out_dir.mkdir()
    (out_dir / "x.jpg").write_bytes(b"old")
    main([str(src), "-o", str(out_dir), "--on-exists", "overwrite"])
    with Image.open(out_dir / "x.jpg") as img:
        assert img.format == "JPEG"


def test_name_collision_in_same_run(tmp_path, out_dir):
    make_photo(tmp_path / "in" / "x.heic")
    make_photo(tmp_path / "in" / "x.png")
    main([str(tmp_path / "in"), "-o", str(out_dir)])
    assert sorted(p.name for p in out_dir.iterdir()) == ["x.jpg", "x_png.jpg"]


def test_output_same_as_input_is_refused(tmp_path):
    src_dir = tmp_path / "in"
    make_photo(src_dir / "x.png")
    assert main([str(src_dir), "-o", str(src_dir)]) == 2
    assert not (src_dir / "x.jpg").exists()


def test_output_inside_input_is_not_rescanned(tmp_path):
    src_dir = tmp_path / "in"
    make_photo(src_dir / "x.png")
    out = src_dir / "converted"
    main([str(src_dir), "-o", str(out)])
    main([str(src_dir), "-o", str(out)])  # 第二次執行不應把 converted/x.jpg 當來源
    assert sorted(p.name for p in out.rglob("*") if p.is_file()) == ["x.jpg"]


def test_same_format_reencode(tmp_path, out_dir):
    src = make_photo(tmp_path / "in" / "x.jpg")
    main([str(src), "-o", str(out_dir), "--reencode", "-q", "20"])
    assert sha(out_dir / "x.jpg") != sha(src)


def test_animated_gif_treated_as_video(tmp_path, out_dir):
    src = tmp_path / "in" / "anim.gif"
    src.parent.mkdir()
    frames = [Image.new("RGB", (64, 48), (i * 40, 0, 0)) for i in range(6)]
    frames[0].save(src, save_all=True, append_images=frames[1:], duration=100)
    assert main([str(src), "-o", str(out_dir)]) == 0
    assert "Video: h264" in video_info(out_dir / "anim.mp4")


def test_video_to_gif(tmp_path, out_dir):
    src = make_video(tmp_path / "in" / "clip.mov", seconds=2)
    assert main([str(src), "-o", str(out_dir), "--video-format", "gif", "--duration", "1"]) == 0
    assert (out_dir / "clip.gif").read_bytes()[:3] == b"GIF"


def test_dry_run_writes_nothing(library, out_dir, capsys):
    assert main([str(library), "-o", str(out_dir), "--dry-run"]) == 0
    assert not out_dir.exists()
    assert "[轉換]" in capsys.readouterr().out


def test_missing_input(tmp_path, out_dir):
    assert main([str(tmp_path / "nope"), "-o", str(out_dir)]) == 2


def test_invalid_quality_rejected(tmp_path):
    with pytest.raises(SystemExit):
        main([str(tmp_path), "-q", "150"])
