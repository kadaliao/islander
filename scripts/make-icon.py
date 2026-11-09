#!/usr/bin/env python3
"""生成 Islander/App/AppIcon.icon（Icon Composer 格式）：
海面上漂着一座黑色的"灵动岛"，岛上长着一棵椰子树，岛里亮着三个小图标。

    python3 scripts/make-icon.py                 # 写 Islander/App/AppIcon.icon
    python3 scripts/make-icon.py --preview DIR   # 同时用 ictool 渲染几张 PNG 预览
"""
import json
import math
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Islander", "App", "AppIcon.icon")
ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

SIZE = 1024

# 岛：胶囊形，水平居中，下半截泡在海里
ISLAND = dict(x=226, y=552, w=572, h=168)
ISLAND_DOTS = [(416, 24), (512, 24), (608, 24)]     # (cx, r)，竖直居中在岛里
HORIZON = 662                                        # 海平面
SUN = (792, 244, 78)                                 # (cx, cy, r)

# 椰子树：树干从岛顶偏右处长出，向左上弯；树冠在左上方
TRUNK = [(646, 600), (680, 492), (610, 362), (516, 304)]   # 三次贝塞尔：起点、两个控制点、终点
TRUNK_WIDTH = (48, 25)                                      # 根部、顶部
CROWN = (516, 298)
# 叶子：(方向角，0 = 向右、逆时针为正；长度；最宽处；下垂程度)
BACK_LEAVES = [(165, 222, 58, 0.42), (72, 180, 52, 0.30), (-6, 215, 56, 0.46)]
FRONT_LEAVES = [(206, 200, 54, 0.30), (128, 196, 54, 0.36), (30, 205, 56, 0.38)]
COCONUTS = [(502, 326, 19), (536, 333, 18)]

COLORS = {
    "island": "#0B0C10",
    "dots": "#FFFFFF",
    "trunk": "#8B5A33",
    "back-leaves": "#1F9D55",
    "front-leaves": "#3CCB72",
    "coconuts": "#5C3A1E",
    "sea": "#1A73E8",
    "sea-deep": "#0D4FB8",
    "sun": "#FFCC33",
}


def bezier(p, t):
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = p
    u = 1 - t
    x = u**3 * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t**3 * x3
    y = u**3 * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t**3 * y3
    return x, y


def outline(center, width, steps=64, cap=True):
    """沿中心线 center(t) 按宽度 width(t) 生成闭合轮廓，两端可加圆头"""
    left, right = [], []
    for i in range(steps + 1):
        t = i / steps
        x, y = center(t)
        a, b = center(max(0, t - 1e-3)), center(min(1, t + 1e-3))
        dx, dy = b[0] - a[0], b[1] - a[1]
        n = math.hypot(dx, dy) or 1
        nx, ny = -dy / n, dx / n
        h = width(t) / 2
        left.append((x + nx * h, y + ny * h))
        right.append((x - nx * h, y - ny * h))
    pts = left + right[::-1]
    if cap:
        # 根部圆头
        x, y = center(0)
        h = width(0) / 2
        a, b = center(0), center(1e-3)
        ang = math.atan2(b[1] - a[1], b[0] - a[0])
        for i in range(1, 16):
            th = ang + math.pi / 2 + math.pi * i / 16
            pts.append((x + h * math.cos(th), y + h * math.sin(th)))
    return pts


def leaf(angle, length, width, droop):
    th = math.radians(angle)
    cx, cy = CROWN

    def center(t):
        x = cx + length * t * math.cos(th)
        y = cy - length * t * math.sin(th) + droop * length * t * t
        return x, y

    def w(t):
        return width * (math.sin(math.pi * min(t, 0.999)) ** 0.7) * (1 - 0.35 * t)

    return outline(center, w, steps=48, cap=False)


def trunk():
    w0, w1 = TRUNK_WIDTH
    return outline(lambda t: bezier(TRUNK, t), lambda t: w0 + (w1 - w0) * t, steps=64)


def wave(top, amplitude, waves, phase):
    pts = []
    for i in range(129):
        x = SIZE * i / 128
        pts.append((x, top + amplitude * math.sin(2 * math.pi * waves * x / SIZE + phase)))
    return pts + [(SIZE, SIZE), (0, SIZE)]


def path(pts):
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts) + " Z"


def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" '
            f'viewBox="0 0 {SIZE} {SIZE}">\n{body}\n</svg>\n')


def shapes():
    i = ISLAND
    cy = i["y"] + i["h"] / 2
    return {
        "island": f'  <rect x="{i["x"]}" y="{i["y"]}" width="{i["w"]}" height="{i["h"]}" '
                  f'rx="{i["h"] / 2}" fill="{COLORS["island"]}"/>',
        "dots": "\n".join(f'  <circle cx="{x}" cy="{cy}" r="{r}" fill="{COLORS["dots"]}"/>'
                          for x, r in ISLAND_DOTS),
        "trunk": f'  <path d="{path(trunk())}" fill="{COLORS["trunk"]}"/>',
        "back-leaves": "\n".join(f'  <path d="{path(leaf(*l))}" fill="{COLORS["back-leaves"]}"/>'
                                 for l in BACK_LEAVES),
        "front-leaves": "\n".join(f'  <path d="{path(leaf(*l))}" fill="{COLORS["front-leaves"]}"/>'
                                  for l in FRONT_LEAVES),
        "coconuts": "\n".join(f'  <circle cx="{x}" cy="{y}" r="{r}" fill="{COLORS["coconuts"]}"/>'
                              for x, y, r in COCONUTS),
        "sea": f'  <path d="{path(wave(HORIZON, 9, 2.5, 0.6))}" fill="{COLORS["sea"]}"/>',
        "sea-deep": f'  <path d="{path(wave(HORIZON + 150, 12, 2, 2.2))}" fill="{COLORS["sea-deep"]}"/>',
        "sun": f'  <circle cx="{SUN[0]}" cy="{SUN[1]}" r="{SUN[2]}" fill="{COLORS["sun"]}"/>',
    }


def layer(name):
    return {"image-name": f"{name}.svg", "name": name}


def document():
    # groups 从前往后排
    return {
        "fill-specializations": [
            {"value": {"linear-gradient": ["srgb:0.30196,0.72549,0.98039,1.00000",
                                           "srgb:0.78039,0.93725,1.00000,1.00000"],
                       "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 0.64}}}},
            {"appearance": "dark",
             "value": {"linear-gradient": ["srgb:0.03922,0.06275,0.17647,1.00000",
                                           "srgb:0.13333,0.21961,0.45098,1.00000"],
                       "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 0.64}}}},
        ],
        "groups": [
            {
                "name": "island",
                "layers": [layer("dots"), layer("island")],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.15},
                "specular": True,
            },
            {
                "name": "palm",
                "layers": [layer("coconuts"), layer("front-leaves"), layer("back-leaves"), layer("trunk")],
                "shadow": {"kind": "layer-color", "opacity": 0.4},
                "translucency": {"enabled": True, "value": 0.2},
                "specular": True,
            },
            {
                "name": "sea",
                "layers": [layer("sea-deep"), layer("sea")],
                "shadow": {"kind": "neutral", "opacity": 0.3},
                "translucency": {"enabled": True, "value": 0.35},
                "specular": True,
            },
            {
                "name": "sun",
                # 深色外观下是月亮
                "layers": [dict(layer("sun"), **{"fill-specializations": [
                    {"appearance": "dark", "value": {"solid": "srgb:0.96078,0.94118,0.84706,1.00000"}},
                ]})],
                "shadow": {"kind": "layer-color", "opacity": 0.3},
                "translucency": {"enabled": True, "value": 0.3},
                "specular": True,
            },
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }


def build():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    os.makedirs(os.path.join(OUT, "Assets"))
    for name, body in shapes().items():
        with open(os.path.join(OUT, "Assets", f"{name}.svg"), "w") as f:
            f.write(svg(body))
    with open(os.path.join(OUT, "icon.json"), "w") as f:
        json.dump(document(), f, indent=2)
        f.write("\n")
    print("wrote", os.path.relpath(OUT, ROOT))


def preview(directory):
    os.makedirs(directory, exist_ok=True)
    for rendition, size in [("Default", 512), ("Dark", 512), ("Default", 64), ("Default", 32)]:
        out = os.path.join(directory, f"icon-{rendition.lower()}-{size}.png")
        subprocess.run([ICTOOL, OUT, "--export-image", "--output-file", out, "--platform", "macOS",
                        "--rendition", rendition, "--width", str(size), "--height", str(size),
                        "--scale", "1"], check=True)
        print("rendered", out)


if __name__ == "__main__":
    build()
    if "--preview" in sys.argv:
        preview(sys.argv[sys.argv.index("--preview") + 1])
