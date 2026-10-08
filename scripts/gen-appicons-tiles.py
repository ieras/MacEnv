#!/usr/bin/env python3
"""生成 AppIcons/tile/ 下根 README 图标墙用的「圆角方形卡片」。

为什么把圆角轮廓烘焙进图片：GitHub 的 HTML sanitizer 会剥掉 style 属性
（html-pipeline 的 SanitizationFilter 白名单里没有 style），border-radius 在 README 里用不了。

输入  AppIcons/png/<名字>-{light,dark}.png   128×128
输出  AppIcons/tile/<名字>-{light,dark}.png  96×96 逻辑（×2 倍 = 192×192 像素）

加一个新图标：把渲染好的 png 放进 AppIcons/png/，然后在 ICONS 里加一项，重跑本脚本。
脚本会重生成全部 tile（幂等，同样的输入出同样的字节）。

依赖 Pillow：/Users/ieras/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3
"""
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "AppIcons/png")
OUT = os.path.join(ROOT, "AppIcons/tile")
os.makedirs(OUT, exist_ok=True)

# 顺序跟根 README 图标墙、AppIcons/README.md 的分节保持一致
ICONS = [
    ("nginx", "Nginx"), ("mysql", "MySQL"), ("mariadb", "MariaDB"), ("redis", "Redis"),
    ("postgresql", "PostgreSQL"), ("clickhouse", "ClickHouse"), ("qdrant", "Qdrant"),
    ("consul", "Consul"), ("etcd", "etcd"),
    ("php", "PHP"), ("go", "Go"), ("java", "Java"), ("python", "Python"), ("maven", "Maven"),
    ("gradle", "Gradle"), ("homebrew", "Homebrew"), ("macports", "MacPorts"), ("sdkman", "SDKMAN"),
    ("composer", "Composer"), ("swoole", "Swoole CLI"), ("tools", "环境工具"), ("ssl", "SSL 证书"),
    ("start", "快捷启动"), ("tray", "菜单栏"), ("gvm", "GVM 矢量字标"), ("gvm-wordmark-color", "GVM 彩色字标"),
    ("gvm-wordmark-solid", "GVM 单色字标"), ("gvm-logo", "GVM 渐变原版"),
]

S = 2                     # 像素倍率
CARD_W, CARD_H = 96, 96
CARD_R = 21
STROKE = 1.5
ICON = 52
ICON_Y = 10
LABEL_Y = 70
LABEL_SIZE = 11

FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
f_label = ImageFont.truetype(FONT, LABEL_SIZE * S, index=0)

# (后缀, 卡片底, 轮廓色, 标签色)
THEMES = [
    ("light", (255, 255, 255), (127, 195, 255), (60, 60, 67)),
    ("dark", (30, 30, 30), (142, 142, 142), (235, 235, 240)),
]


def p(v):
    return int(round(v * S))


SS = 4                    # 超采样倍率：PIL 画圆角不做抗锯齿，放大 4 倍画完再缩回来

for suffix, bg, stroke, label_c in THEMES:
    for name, label in ICONS:
        big = (CARD_W * SS, CARD_H * SS)
        # 圆角外必须透明。用不透明底（RGB）的话，深色图块的四角也是深色的，
        # 圆角直接被吃掉 —— 在浅色页面上看起来就是一个直角黑方块。
        rgb = Image.new("RGB", big, bg)
        ImageDraw.Draw(rgb).rounded_rectangle([0, 0, big[0] - 1, big[1] - 1],
                                              radius=CARD_R * SS, outline=stroke,
                                              width=round(STROKE * SS))
        alpha = Image.new("L", big, 0)
        ImageDraw.Draw(alpha).rounded_rectangle([0, 0, big[0] - 1, big[1] - 1],
                                                radius=CARD_R * SS, fill=255)

        size = (p(CARD_W), p(CARD_H))
        im = rgb.resize(size, Image.LANCZOS)             # RGB 与 alpha 分开缩，
        im.putalpha(alpha.resize(size, Image.LANCZOS))   # 避免非预乘插值产生暗边

        ic = Image.open(f"{SRC}/{name}-{suffix}.png").convert("RGBA").resize((p(ICON), p(ICON)), Image.LANCZOS)
        im.paste(ic, (p((CARD_W - ICON) / 2), p(ICON_Y)), ic)

        ImageDraw.Draw(im, "RGBA").text((p(CARD_W / 2), p(LABEL_Y)), label,
                                        font=f_label, fill=label_c, anchor="ma")

        # 带 alpha 的图不能用 MEDIANCUT（会丢透明），得用 FASTOCTREE —— 它连 alpha 一起量化，
        # 22.8 KB 直接降到 4.8 KB，肉眼无差。64 色在文字上能看出台阶，128 色看不出。
        im.quantize(colors=128, method=Image.FASTOCTREE).save(
            f"{OUT}/{name}-{suffix}.png", optimize=True)

print(f"wrote {len(ICONS) * len(THEMES)} tiles to {OUT}")
