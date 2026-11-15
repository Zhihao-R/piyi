# 把示例卡的理解结果（标题、描述、详细描述、标签、要点）写进示例清单，随 App 发：新用户打开示例画板不用调模型。
# 用法：先用一份全新的资料库、带着密钥打开 App 一次，等示例卡都理解完，再
#   python3 scripts/seed_understood.py <那份资料库的 library.sqlite> <zh|en>
# 中文界面打开的写进 zh，英文界面打开的写进 en。只读资料库。
import json, sys
from seed_match import board_cards, load_items, match, open_db, save_items

db_path, language = sys.argv[1], sys.argv[2]
assert language in ("zh", "en")
items = load_items()
rows = board_cards(open_db(db_path), {"zh": "示例", "en": "Sample"}[language],
                   "c.generatedTitle, c.caption, c.detail, c.tags, c.summary, c.summaryAnchors")
assert len(rows) == len(items), f"画板上 {len(rows)} 张，清单 {len(items)} 项"
missing = [r["kind"] for r in rows if r["generatedTitle"] is None]
assert not missing, f"还有 {len(missing)} 张没理解完"
for r in rows:
    it = match(r, items)
    it.setdefault("understood", {})[language] = {k: v for k, v in {
        "title": r["generatedTitle"], "caption": r["caption"], "detail": r["detail"], "tags": json.loads(r["tags"]),
        "summary": r["summary"], "anchors": json.loads(r["summaryAnchors"]) if r["summaryAnchors"] else None,
    }.items() if v is not None}
save_items(items)
print(f"写进了 {len(rows)} 张的{language}理解结果")
