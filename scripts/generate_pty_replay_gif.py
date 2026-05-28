#!/usr/bin/env python3
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


WIDTH = 980
HEIGHT = 560
PAD_X = 28
PAD_Y = 28
HEADER_H = 48
LINE_H = 18
FONT_SIZE = 13

PALETTE = {
    "bg": (10, 10, 11),
    "panel": (17, 17, 17),
    "stroke": (58, 58, 64),
    "text": (226, 226, 229),
    "muted": (168, 168, 168),
    "accent": (102, 217, 194),
    "warn": (232, 164, 92),
    "danger": (248, 113, 113),
    "yellow": (251, 191, 36),
}


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print("usage: generate_pty_replay_gif.py OUTPUT [PAYLOAD_JSON]", file=sys.stderr)
        return 2

    output = Path(sys.argv[1])
    if len(sys.argv) == 3:
        with open(sys.argv[2], "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    else:
        payload = json.load(sys.stdin)
    frames = payload.get("frames", [])
    if not frames:
        print("no frames", file=sys.stderr)
        return 1

    output.parent.mkdir(parents=True, exist_ok=True)
    images = [render_frame(frame) for frame in frames]
    durations = [int(frame.get("duration_ms", 900)) for frame in frames]

    images[0].save(
        output,
        save_all=True,
        append_images=images[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=2,
    )

    print(json.dumps({"path": str(output), "frames": len(images), "bytes": output.stat().st_size}))
    return 0


def render_frame(frame):
    image = Image.new("RGB", (WIDTH, HEIGHT), PALETTE["bg"])
    draw = ImageDraw.Draw(image)
    font = load_font(FONT_SIZE)
    title_font = load_font(15)

    draw.rounded_rectangle(
        (10, 10, WIDTH - 10, HEIGHT - 10),
        radius=12,
        fill=PALETTE["panel"],
        outline=PALETTE["stroke"],
        width=1,
    )
    draw.ellipse((PAD_X, PAD_Y, PAD_X + 10, PAD_Y + 10), fill=PALETTE["danger"])
    draw.ellipse((PAD_X + 18, PAD_Y, PAD_X + 28, PAD_Y + 10), fill=PALETTE["yellow"])
    draw.ellipse((PAD_X + 36, PAD_Y, PAD_X + 46, PAD_Y + 10), fill=PALETTE["accent"])
    draw.text((PAD_X + 62, PAD_Y - 4), "ourocode", fill=PALETTE["accent"], font=title_font)
    draw.text((PAD_X + 158, PAD_Y - 4), frame.get("title", "PTY replay"), fill=PALETTE["muted"], font=title_font)

    y = PAD_Y + HEADER_H
    for line in visible_lines(frame.get("text", "")):
        line = normalize_text(line)
        draw.text((PAD_X, y), line, fill=line_color(line), font=font)
        y += LINE_H

    return image


def visible_lines(text):
    lines = [normalize_text(line)[:118] for line in text.splitlines() if line.strip()]
    max_lines = (HEIGHT - PAD_Y - HEADER_H - 24) // LINE_H
    if len(lines) <= max_lines:
        return lines
    return lines[: max_lines - 1] + ["..."]


def line_color(line):
    stripped = line.strip()
    if any(token in stripped for token in ("■", "⬝■", "Queue a follow-up", ">>", "●", "ready", "passed")):
        return PALETTE["accent"]
    if any(token in stripped for token in ("INTERVIEW", "workflow", "approval", "Auto", "commands")):
        return PALETTE["warn"]
    if stripped.startswith(("Actions", "Shortcuts", "Next", "Status")):
        return PALETTE["muted"]
    return PALETTE["text"]


def normalize_text(line):
    return line.replace("\\u25cf", "●").replace("\\u00b7", "·")


def load_font(size):
    candidates = [
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Monaco.ttf",
        "/Library/Fonts/Arial Unicode.ttf",
    ]
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            pass
    return ImageFont.load_default()


if __name__ == "__main__":
    raise SystemExit(main())
