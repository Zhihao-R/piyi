# 示例画板的几个脚本共用：读写示例清单，把资料库里的一张卡认回清单里的那一项。
# 卡按它收进来时的来路认：图片和网址按网址，引文按原文，文件按文件名（文档按标题），音频、视频、动图、长截图按种类。
# 原版和各语言的版本（清单项里的 variants）都认。
import json, os, re, sqlite3

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../Sources/Collage/Resources/Seed")
MANIFEST = f"{ROOT}/manifest.json"
DEFAULT_DB = os.path.expanduser("~/Library/Application Support/Collage/library.sqlite")

def load_items():
    return json.load(open(MANIFEST))

def save_items(items):
    json.dump(items, open(MANIFEST, "w"), ensure_ascii=False, indent=1)
    open(MANIFEST, "a").write("\n")

def open_db(path):
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    return db

def board_cards(db, name, columns):
    """一块画板上的卡，按叠放顺序；columns 是要读的列（p. 摆放，c. 卡片）"""
    board = db.execute("SELECT id FROM board WHERE name = ?", (name,)).fetchone()
    assert board, f"没有叫「{name}」的画板"
    return db.execute(f"""SELECT {columns}, c.kind, c.url, c.sourceURL, c.text, c.title, c.format
                          FROM placement p JOIN card c ON c.id = p.cardId WHERE p.boardId = ? ORDER BY p.z""", (board["id"],)).fetchall()

def _bare(text):
    """去掉标点、空格，不分大小写：文件名里的「-」和文中标题里的「·」「：」当成一样"""
    return re.sub(r"[\s\-·：:]", "", text or "").lower()

def _versions(it):
    """原版和各语言的版本（清单项里的 variants）"""
    return [it] + [{**it, **v} for v in it.get("variants", {}).values()]

def match(row, items):
    """这张卡对应清单里的哪一项"""
    found = [it for it in items if any(_same(row, v) for v in _versions(it))]
    assert len(found) == 1, (dict(row), [it.get("file") or it.get("url") or it.get("text") for it in found])
    return found[0]

def _same(r, it):
    k = it["kind"]
    if k in ("image", "link"): return bool(it.get("url")) and it["url"] in (r["url"], r["sourceURL"])
    if k == "url": return it["url"] == r["url"]
    if k == "quote": return it["text"] == r["text"]
    ext = os.path.splitext(it["file"])[1].lower()
    if r["kind"] == "document": return bool(r["title"]) and _bare(r["title"]) == _bare(os.path.splitext(it["file"])[0])
    if r["kind"] == "audio": return ext == ".mp3"
    if r["kind"] == "video": return not r["url"] and ext == ".mp4"
    # 没有网址的图只有两张：长截图（格式记成「长图」）和奔马动图
    if r["kind"] == "image" and not r["url"] and not r["sourceURL"]: return ext in (".gif", ".jpg") and (ext == ".jpg") == (r["format"] == "长图")
    return False
