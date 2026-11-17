# Shared by the sample board scripts: reads and writes the sample list, and matches a card in the library back to its entry in the list.
# Cards are matched by how they were collected: images and URLs by URL, quotes by original text, files by file name (documents by title), audio, video, animated images and long screenshots by kind.
# Both the original and each language's versions (variants in the list entries) are matched.
import json, os, re, sqlite3

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../Sources/Piyi/Resources/Seed")
MANIFEST = f"{ROOT}/manifest.json"
DEFAULT_DB = os.path.expanduser("~/Library/Application Support/Piyi/library.sqlite")

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
    """Cards on a board, in stacking order; columns are the columns to read (p. placement, c. card)"""
    board = db.execute("SELECT id FROM board WHERE name = ?", (name,)).fetchone()
    assert board, f"No board named \"{name}\""
    return db.execute(f"""SELECT {columns}, c.kind, c.url, c.sourceURL, c.text, c.title, c.format
                          FROM placement p JOIN card c ON c.id = p.cardId WHERE p.boardId = ? ORDER BY p.z""", (board["id"],)).fetchall()

def _bare(text):
    """Drop punctuation and spaces, ignore case: "-" in file names and "·" or "：" in titles count as the same"""
    return re.sub(r"[\s\-·：:]", "", text or "").lower()

def _versions(it):
    """The original and each language version (variants in the manifest item)"""
    return [it] + [{**it, **v} for v in it.get("variants", {}).values()]

def match(row, items):
    """Which manifest item this card corresponds to"""
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
    # Only two images have no URL: the long screenshot (format recorded as "长图") and the galloping-horse animated image
    if r["kind"] == "image" and not r["url"] and not r["sourceURL"]: return ext in (".gif", ".jpg") and (ext == ".jpg") == (r["format"] == "长图")
    return False
