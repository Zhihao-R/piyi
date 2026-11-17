# Writes the sample cards' understanding results (title, description, detailed description, tags, key points) into the sample list, shipped with the App: new users opening the sample board don't need to call a model.
# Usage: first open the App once with a fresh library and a key, wait until all sample cards are understood, then
#   python3 scripts/seed_understood.py <that library's library.sqlite> <zh|en>
# Opened with the Chinese interface, write to zh; with the English interface, write to en. Reads the library only.
import json, sys
from seed_match import board_cards, load_items, match, open_db, save_items

db_path, language = sys.argv[1], sys.argv[2]
assert language in ("zh", "en")
items = load_items()
rows = board_cards(open_db(db_path), {"zh": "示例", "en": "Sample"}[language],
                   "c.generatedTitle, c.caption, c.detail, c.tags, c.summary, c.summaryAnchors")
assert len(rows) == len(items), f"{len(rows)} cards on the board, {len(items)} items in the manifest"
missing = [r["kind"] for r in rows if r["generatedTitle"] is None]
assert not missing, f"{len(missing)} cards not yet understood"
for r in rows:
    it = match(r, items)
    it.setdefault("understood", {})[language] = {k: v for k, v in {
        "title": r["generatedTitle"], "caption": r["caption"], "detail": r["detail"], "tags": json.loads(r["tags"]),
        "summary": r["summary"], "anchors": json.loads(r["summaryAnchors"]) if r["summaryAnchors"] else None,
    }.items() if v is not None}
save_items(items)
print(f"Wrote {language} understanding results for {len(rows)} cards")
