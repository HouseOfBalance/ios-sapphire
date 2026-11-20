#!/usr/bin/env python3
"""Ve icon SapphireTools (gem xanh sapphire) -> AppIcon60x60@2x.png (120) va @3x.png (180).
Chay: python3 tools/make_icon.py   (can Pillow)"""
from PIL import Image, ImageDraw
S = 1024
img = Image.new("RGB", (S, S))
px = img.load()
for y in range(S):                      # nen gradient xanh dam -> xanh sang
    t = y / (S - 1)
    c = (int(8 + 22 * t), int(26 + 70 * t), int(80 + 140 * t))
    for x in range(S):
        px[x, y] = c
d = ImageDraw.Draw(img)
cx = S // 2
top, mid, bot = 270, 430, 800
l, r = 230, S - 230
tl, tr = 380, S - 380
P = lambda *a: [tuple(p) for p in a]
d.polygon(P((tl, top), (tr, top), (r, mid), (l, mid)), fill=(120, 190, 255))   # crown
d.polygon(P((tl, top), (cx, top), (cx - 150, mid), (l, mid)), fill=(160, 215, 255))
d.polygon(P((cx, top), (tr, top), (r, mid), (cx + 150, mid)), fill=(90, 160, 240))
d.polygon(P((l, mid), (cx - 150, mid), (cx, bot)), fill=(40, 105, 215))        # pavilion
d.polygon(P((cx - 150, mid), (cx + 150, mid), (cx, bot)), fill=(25, 75, 180))
d.polygon(P((cx + 150, mid), (r, mid), (cx, bot)), fill=(15, 55, 150))
d.line(P((l, mid), (r, mid)), fill=(225, 242, 255), width=6)
d.polygon(P((cx - 110, 300), (cx - 40, 300), (cx - 80, 400), (cx - 150, 400)), fill=(235, 248, 255))  # highlight
for n, size in (("AppIcon60x60@2x.png", 120), ("AppIcon60x60@3x.png", 180)):
    img.resize((size, size), Image.LANCZOS).save("icons/" + n)
img.save("icons/preview-1024.png")
print("ok")
