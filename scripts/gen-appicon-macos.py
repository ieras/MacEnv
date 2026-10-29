#!/usr/bin/env python3
"""按 macOS 图标网格重生成 AppIcon 全套尺寸。

Apple 的网格（Big Sur 至今，macOS 26/27 仍未变）：1024 画布 / 主体 824×824 居中 /
每边 100px 透明边距。Dock 对所有 App 用同一个画布尺寸渲染，主体铺满画布的图标会比
邻居宽高各大 24%，在 macOS 26 的紧凑 Dock 容器里直接溢出。

主体形状是圆角方形，圆角半径 185.4。实测系统图标（Notes/Calendar/Terminal）顶行起点
落在主体宽度的 20.4%、45° 距角 6.3%，与半径 185.4 的标准圆弧只差 1-2px，用圆弧即可。
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Design/macenv-appicon-1024.png"
OUT = ROOT / "MacEnv/Assets.xcassets/AppIcon.appiconset"

CANVAS = 1024
BODY = 824
RADIUS = 185.4
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def fill_corners(src: Image.Image) -> Image.Image:
    """圆角外的透明像素按行用最近的不透明像素填满，保住原图的纵向渐变。"""
    a = np.array(src)
    alpha = a[:, :, 3]
    for y in range(a.shape[0]):
        xs = np.flatnonzero(alpha[y] > 8)
        if xs.size == 0:
            continue
        a[y, :xs[0]] = a[y, xs[0]]
        a[y, xs[-1] + 1:] = a[y, xs[-1]]
    return Image.fromarray(a)


def rounded_mask(size: int, radius: float) -> Image.Image:
    """圆角矩形遮罩，直接在目标分辨率上算有符号距离场，边缘固定 1px 抗锯齿。
    不走超采样再缩小——那会在小尺寸上振铃，圆角占比从 20.5% 漂到 15%。
    （Pillow 的 rounded_rectangle 几何也会内缩约 3.5%，对不上 Apple 的 185.4。）"""
    yy, xx = np.mgrid[0:size, 0:size]
    cx = np.clip(xx, radius, size - 1 - radius)
    cy = np.clip(yy, radius, size - 1 - radius)
    dist = np.hypot(xx - cx, yy - cy) - radius
    return Image.fromarray((np.clip(0.5 - dist, 0, 1) * 255).astype(np.uint8), "L")


def main() -> int:
    if not SRC.exists():
        print(f"缺源图：{SRC}", file=sys.stderr)
        return 1

    src = fill_corners(Image.open(SRC).convert("RGBA"))
    for size in SIZES:
        # 每个尺寸单独缩图案、单独套遮罩：整体缩放会把抗锯齿边缘再糊一次，
        # 圆角占比会从 20.5% 漂到 18%。
        body = round(size * BODY / CANVAS)
        art = src.resize((body, body), Image.LANCZOS)
        alpha = np.array(art.getchannel("A")).astype(np.uint16) * np.array(rounded_mask(body, RADIUS * body / BODY)) // 255
        art.putalpha(Image.fromarray(alpha.astype(np.uint8), "L"))

        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        canvas.alpha_composite(art, ((size - body) // 2, (size - body) // 2))
        path = OUT / f"macenv-{size}.png"
        canvas.save(path)

        a = np.array(canvas)[:, :, 3]
        ys, xs = np.where(a > 32)
        w = xs.max() - xs.min() + 1
        r = np.flatnonzero(a[ys.min()] > 32)[0] - xs.min()
        print(f"{path.name:16s} {size:>4}px  主体 {w:>4}px  占比 {w / size * 100:5.1f}%  "
              f"bbox ({xs.min()},{ys.min()},{xs.max() + 1},{ys.max() + 1})  圆角 {r / w * 100:.1f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
