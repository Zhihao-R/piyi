# Exports a sample board arranged by hand in the App as positions for the sample list (python3 scripts/seed_export.py "board name" [library path]).
# Writes back top-left corner, width/height and rotation; the list is in stacking order (cards created first when collecting are below), with the top-left moved to (0, 0). Reads the library only.
import math, sys
from seed_match import DEFAULT_DB, board_cards, load_items, match, open_db, save_items

items = load_items()
rows = board_cards(open_db(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_DB), sys.argv[1], "p.x, p.y, p.width, p.height, p.rotation, p.crop, p.flipX, p.flipY")
assert not any(r["crop"] or r["flipX"] or r["flipY"] for r in rows), "Some cards are cropped or flipped, which the sample manifest doesn't support yet"
placed = [(match(r, items), r) for r in rows]
assert len({id(it) for it, _ in placed}) == len(placed) == len(items), "The cards on the board don't match the manifest"
x0 = min(r["x"] for _, r in placed); y0 = min(r["y"] for _, r in placed)
for it, r in placed:
    it["x"], it["y"] = round(r["x"] - x0), round(r["y"] - y0)
    it["width"], it["height"] = round(r["width"]), round(r["height"])
    degrees = round(math.degrees(r["rotation"]), 1)
    if degrees: it["rotation"] = degrees
    else: it.pop("rotation", None)
save_items([it for it, _ in placed])
print(f"Exported {len(placed)} cards, board {round(max(r['x'] + r['width'] for _, r in placed) - x0)} × {round(max(r['y'] + r['height'] for _, r in placed) - y0)}")
