import json, os, sys

out = sys.argv[1]
os.makedirs(f"{out}/Assets", exist_ok=True)
for f in os.listdir(f"{out}/Assets"):
    os.remove(f"{out}/Assets/{f}")


def p3(hexstr):
    h = hexstr.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"display-p3:{r:.4f},{g:.4f},{b:.4f},1.0"


BG = [p3("#4B4E52"), p3("#1C1E20")]
INK = p3("#CDD1A6")
INK2 = p3("#868C5E")


def svg(name, body):
    with open(f"{out}/Assets/{name}", "w") as f:
        f.write('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
                f'<g fill="#FFFFFF">{body}</g></svg>')


concept = sys.argv[2] if len(sys.argv) > 2 else "tray"
MID = p3("#A9AE84")


def card(x, y, w, h, angle, r=46):
    cx, cy = x + w / 2, y + h / 2
    return (f'<g transform="rotate({angle} {cx} {cy})">'
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" ry="{r}"/></g>')


def group(name, ink):
    return {
        "layers": [{"image-name": f"{name}.svg", "name": name, "glass": True, "fill": {"solid": ink}}],
        "shadow": {"kind": "neutral", "opacity": 0.5},
        "translucency": {"enabled": True, "value": 0.25},
        "specular": True,
    }


if concept == "tray":
    svg("back.svg", card(450, 244, 276, 380, 10, 44))
    svg("front.svg", card(302, 272, 276, 380, -8, 44))
    svg("tray.svg", '<path d="M176,598 H848 A28,28 0 0 1 874,634 L846,724 A90,90 0 0 1 760,788 H264 '
                    'A90,90 0 0 1 178,724 L150,634 A28,28 0 0 1 176,598 Z"/>')
    groups = [group("tray", INK2), group("front", INK), group("back", INK2)]
elif concept == "shelf":
    svg("back.svg", card(500, 318, 240, 340, 13, 40))
    svg("front.svg", card(300, 300, 248, 372, 0, 40))
    svg("bar.svg", '<rect x="170" y="672" width="684" height="86" rx="43" ry="43"/>')
    groups = [group("bar", INK2), group("front", INK), group("back", INK2)]
else:
    svg("back.svg", card(388, 206, 300, 400, 12))
    svg("middle.svg", card(356, 270, 300, 400, 2))
    svg("front.svg", card(324, 334, 300, 400, -9))
    groups = [group("front", INK), group("middle", MID), group("back", INK2)]

doc = {
    "fill": {"linear-gradient": BG},
    "groups": groups,
    "supported-platforms": {"squares": ["macOS"]},
}
with open(f"{out}/icon.json", "w") as f:
    json.dump(doc, f, indent=2)
print(out)
