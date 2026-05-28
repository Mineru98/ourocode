#!/usr/bin/env python3
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


CELL_W = 8
LINE_H = 16
FONT_SIZE = 12

PALETTES = {
    "dark": {
        "background": (10, 10, 11),
        "text": (226, 226, 229),
        "accent": (102, 217, 194),
        "warn": (232, 164, 92),
        "muted": (168, 168, 168),
    },
    "light": {
        "background": (250, 250, 249),
        "text": (34, 34, 38),
        "accent": (20, 102, 90),
        "warn": (153, 96, 35),
        "muted": (98, 98, 104),
    },
}


def main() -> int:
    if len(sys.argv) == 2:
        with open(sys.argv[1], "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    else:
        payload = json.load(sys.stdin)
    lines = [str(line) for line in payload.get("lines", [])]
    output = Path(payload["path"])
    theme = payload.get("theme", "dark")
    palette = PALETTES.get(theme, PALETTES["dark"])

    output.parent.mkdir(parents=True, exist_ok=True)
    width = max(max((display_width(line) for line in lines), default=1) * CELL_W, 1)
    height = max(len(lines), 1) * LINE_H
    image = Image.new("RGB", (width, height), palette["background"])
    draw = ImageDraw.Draw(image)
    font = load_font(FONT_SIZE)

    for row, line in enumerate(lines):
        draw.text((1, row * LINE_H + 1), normalize_text(line), fill=line_color(line, palette), font=font)

    image.save(output, format="PNG", optimize=True)
    pixels = image.load()
    bg = palette["background"]
    accent = palette["accent"]
    non_bg = 0
    accent_pixels = 0

    for y in range(height):
        for x in range(width):
            value = pixels[x, y]
            if value != bg:
                non_bg += 1
            if value == accent:
                accent_pixels += 1

    print(
        json.dumps(
            {
                "path": str(output),
                "width": width,
                "height": height,
                "bytes": output.stat().st_size,
                "background_rgb": list(bg),
                "non_background_pixels": non_bg,
                "accent_pixels": accent_pixels,
                "top_left_rgb": list(pixels[0, 0]),
                "center_rgb": list(pixels[width // 2, height // 2]),
                "renderer": "font",
            }
        )
    )
    return 0


def display_width(line: str) -> int:
    return sum(1 if ord(ch) < 128 else 2 for ch in line)


def normalize_text(line: str) -> str:
    return line.replace("\\u25cf", "●").replace("\\u00b7", "·")


def line_color(line, palette):
    stripped = line.strip()
    if any(token in line for token in ("■", "⬝■", "Queue a follow-up", ">>", "●", "ready", "passed")):
        return palette["accent"]
    if any(token in line for token in ("INTERVIEW", "workspace", "capture", "approval", "Auto")):
        return palette["warn"]
    if stripped.startswith(("Actions", "Shortcuts", "Next", "Status")):
        return palette["muted"]
    return palette["text"]


def load_font(size):
    candidates = [
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Monaco.ttf",
        "/Library/Fonts/Arial Unicode.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationMono-Regular.ttf",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


if __name__ == "__main__":
    raise SystemExit(main())
