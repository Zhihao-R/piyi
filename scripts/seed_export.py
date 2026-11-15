# 把 App 里亲手摆好的一块示例画板导出成示例清单的位置（python3 scripts/seed_export.py "画板名" [资料库路径]）。
# 每张卡按它收进来时的来路认回清单里的那一项：图片和网址按网址，引文按原文，文件按文件名；
# 写回左上角、宽高、旋转，清单按叠放顺序排（收集时先建的卡在下面）。左上角挪到 (0, 0)。只读资料库。
import json, math, os, re, sqlite3, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../Sources/Collage/Resources/Seed")
board_name = sys.argv[1]
db_path = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/Library/Application Support/Collage/library.sqlite")
items = json.load(open(f"{ROOT}/manifest.json"))

db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
db.row_factory = sqlite3.Row
board = db.execute("SELECT id FROM board WHERE name = ?", (board_name,)).fetchone()
assert board, f"没有叫「{board_name}」的画板"
rows = db.execute("""SELECT p.x, p.y, p.width, p.height, p.rotation, p.z, p.crop, p.flipX, p.flipY,
                            c.kind, c.url, c.sourceURL, c.text, c.title, c.format
                     FROM placement p JOIN card c ON c.id = p.cardId WHERE p.boardId = ? ORDER BY p.z""", (board["id"],)).fetchall()
assert not any(r["crop"] or r["flipX"] or r["flipY"] for r in rows), "有裁剪或翻转的卡：示例清单还不支持"

def bare(text):
    """去掉标点和空格：文件名里的「-」和文中标题里的「·」「：」当成一样"""
    return re.sub(r"[\s\-·：:]", "", text or "")

def match(r):
    """这张卡对应清单里的哪一项"""
    candidates = []
    for it in items:
        k = it["kind"]
        if k in ("image", "link") and it.get("url") and it["url"] in (r["url"], r["sourceURL"]): candidates.append(it)
        elif k == "url" and it["url"] == r["url"]: candidates.append(it)
        elif k == "quote" and it["text"] == r["text"]: candidates.append(it)
        elif k == "file":
            f = it["file"]; ext = os.path.splitext(f)[1].lower()
            # 文件收进来后：文档按文件名或文中标题起名，音频、视频、动图、长截图按种类认
            if r["kind"] == "document" and r["title"] and bare(r["title"]) == bare(os.path.splitext(f)[0]): candidates.append(it)
            elif r["kind"] == "audio" and ext == ".mp3": candidates.append(it)
            elif r["kind"] == "video" and not r["url"] and ext == ".mp4": candidates.append(it)
            elif r["kind"] == "image" and not r["url"] and not r["sourceURL"] and ext in (".gif", ".jpg"):
                # 没有网址的图只有两张：长截图（格式记成「长图」）和奔马动图
                if (ext == ".jpg") == (r["format"] == "长图"): candidates.append(it)
    assert len(candidates) == 1, (dict(r), [c.get("file") or c.get("url") or c.get("text") for c in candidates])
    return candidates[0]

placed = [(match(r), r) for r in rows]
assert len({id(it) for it, _ in placed}) == len(placed) == len(items), "画板上的卡和清单对不上"
x0 = min(r["x"] for _, r in placed); y0 = min(r["y"] for _, r in placed)
for it, r in placed:
    it["x"], it["y"] = round(r["x"] - x0), round(r["y"] - y0)
    it["width"], it["height"] = round(r["width"]), round(r["height"])
    degrees = round(math.degrees(r["rotation"]), 1)
    if degrees: it["rotation"] = degrees
    else: it.pop("rotation", None)
order = [it for it, _ in placed]
json.dump(order, open(f"{ROOT}/manifest.json", "w"), ensure_ascii=False, indent=1)
open(f"{ROOT}/manifest.json", "a").write("\n")
print(f"导出 {len(order)} 张，画板 {round(max(r['x'] + r['width'] for _, r in placed) - x0)} × {round(max(r['y'] + r['height'] for _, r in placed) - y0)}")
