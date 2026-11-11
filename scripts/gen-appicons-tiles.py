#!/usr/bin/env python3
"""生成 AppIcons/tile/ 下根 README 图标墙用的「圆角方形卡片」，以及 AppIcons/wall/ 下的一行一张合成图。

为什么把圆角轮廓烘焙进图片：GitHub 的 HTML sanitizer 会剥掉 style 属性
（html-pipeline 的 SanitizationFilter 白名单里没有 style），border-radius 在 README 里用不了。
为什么整行合成一张图：多张固定像素宽的 <img> 在容器变窄时必然换行，
一行一张图配 width="100%" 才不会换行，而且永远铺满容器宽度。

输入  AppIcons/png/<名字>-{light,dark}.png   128×128
输出  AppIcons/tile/<名字>-{light,dark}.png  96×96 逻辑（×2 倍 = 192×192 像素）
      AppIcons/wall/<主题>-<行号>.png      2080×240 透明底，10 列槽位

加一个新图标：把渲染好的 png 放进 AppIcons/png/，然后在 ICONS 里加一项，
按 README 的行数调 WALL_ROWS，重跑本脚本。脚本会重生成全部 tile 与 wall（幂等）。

依赖 Pillow：/Users/ieras/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3
"""
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "AppIcons/png")
OUT = os.path.join(ROOT, "AppIcons/tile")
os.makedirs(OUT, exist_ok=True)

# 顺序对齐 README 图标墙
ICONS = [
    ("nginx", "Nginx"), ("mysql", "MySQL"), ("mariadb", "MariaDB"), ("redis", "Redis"),
    ("postgresql", "PostgreSQL"), ("clickhouse", "ClickHouse"), ("qdrant", "Qdrant"), ("neo4j", "Neo4j"),
    ("rabbitmq", "RabbitMQ"), ("kafka", "Kafka"),
    ("minio", "MinIO"), ("rustfs", "RustFS"),
    ("consul", "Consul"), ("etcd", "etcd"),
    ("php", "PHP"), ("go", "Go"), ("java", "Java"), ("python", "Python"), ("node", "Node"), ("rust", "Rust"),
    ("erlang", "Erlang"),
    ("maven", "Maven"), ("gradle", "Gradle"), ("homebrew", "Homebrew"), ("macports", "MacPorts"),
    ("sdkman", "SDKMAN"), ("nvm", "nvm"), ("fnm", "fnm"),
    ("composer", "Composer"), ("swoole", "Swoole CLI"), ("tools", "环境工具"),
    ("ssl", "SSL 证书"), ("start", "快捷启动"), ("tray", "菜单栏"), ("gvm", "GVM 矢量字标"),
    ("gvm-wordmark-color", "GVM 彩色字标"), ("gvm-wordmark-solid", "GVM 单色字标"), ("gvm-logo", "GVM 渐变原版"),
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


SS = 4                    # 超采样倍率

for suffix, bg, stroke, label_c in THEMES:
    for name, label in ICONS:
        big = (CARD_W * SS, CARD_H * SS)
        # 圆角外透明
        rgb = Image.new("RGB", big, bg)
        ImageDraw.Draw(rgb).rounded_rectangle([0, 0, big[0] - 1, big[1] - 1],
                                              radius=CARD_R * SS, outline=stroke,
                                              width=round(STROKE * SS))
        alpha = Image.new("L", big, 0)
        ImageDraw.Draw(alpha).rounded_rectangle([0, 0, big[0] - 1, big[1] - 1],
                                                radius=CARD_R * SS, fill=255)

        size = (p(CARD_W), p(CARD_H))
        im = rgb.resize(size, Image.LANCZOS)
        im.putalpha(alpha.resize(size, Image.LANCZOS))

        ic = Image.open(f"{SRC}/{name}-{suffix}.png").convert("RGBA").resize((p(ICON), p(ICON)), Image.LANCZOS)
        im.paste(ic, (p((CARD_W - ICON) / 2), p(ICON_Y)), ic)

        ImageDraw.Draw(im, "RGBA").text((p(CARD_W / 2), p(LABEL_Y)), label,
                                        font=f_label, fill=label_c, anchor="ma")

        # FASTOCTREE 保留 alpha
        im.quantize(colors=128, method=Image.FASTOCTREE).save(
            f"{OUT}/{name}-{suffix}.png", optimize=True)

WALL = os.path.join(ROOT, "AppIcons/wall")
os.makedirs(WALL, exist_ok=True)

WALL_ROWS = [10, 10, 10, 8]      # 每行图标数，顺序对齐 README 图标墙
SLOT, TILE_PX, ROW_H = 208, 192, 240
WIDTH = SLOT * max(WALL_ROWS)
GAP_X = (SLOT - TILE_PX) // 2
GAP_Y = (ROW_H - TILE_PX) // 2

for suffix, *_ in THEMES:
    offset = 0
    for index, count in enumerate(WALL_ROWS, 1):
        strip = Image.new("RGBA", (WIDTH, ROW_H), (0, 0, 0, 0))
        x0 = (WIDTH - count * SLOT) // 2
        for column, (name, _) in enumerate(ICONS[offset:offset + count]):
            tile = Image.open(f"{OUT}/{name}-{suffix}.png").convert("RGBA")
            strip.alpha_composite(tile, (x0 + column * SLOT + GAP_X, GAP_Y))
        strip.save(f"{WALL}/{suffix}-{index}.png", optimize=True)
        offset += count

print(f"wrote {len(ICONS) * len(THEMES)} tiles to {OUT}")
print(f"wrote {len(WALL_ROWS) * len(THEMES)} wall strips to {WALL}")
