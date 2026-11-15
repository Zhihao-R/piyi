# 把 App 里亲手摆好的一块示例画板导出成示例清单的位置（python3 scripts/seed_export.py "画板名" [资料库路径]）。
# 写回左上角、宽高、旋转，清单按叠放顺序排（收集时先建的卡在下面），左上角挪到 (0, 0)。只读资料库。
import math, sys
from seed_match import DEFAULT_DB, board_cards, load_items, match, open_db, save_items

items = load_items()
rows = board_cards(open_db(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_DB), sys.argv[1], "p.x, p.y, p.width, p.height, p.rotation, p.crop, p.flipX, p.flipY")
assert not any(r["crop"] or r["flipX"] or r["flipY"] for r in rows), "有裁剪或翻转的卡：示例清单还不支持"
placed = [(match(r, items), r) for r in rows]
assert len({id(it) for it, _ in placed}) == len(placed) == len(items), "画板上的卡和清单对不上"
x0 = min(r["x"] for _, r in placed); y0 = min(r["y"] for _, r in placed)
for it, r in placed:
    it["x"], it["y"] = round(r["x"] - x0), round(r["y"] - y0)
    it["width"], it["height"] = round(r["width"]), round(r["height"])
    degrees = round(math.degrees(r["rotation"]), 1)
    if degrees: it["rotation"] = degrees
    else: it.pop("rotation", None)
save_items([it for it, _ in placed])
print(f"导出 {len(placed)} 张，画板 {round(max(r['x'] + r['width'] for _, r in placed) - x0)} × {round(max(r['y'] + r['height'] for _, r in placed) - y0)}")
