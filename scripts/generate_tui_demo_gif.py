#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "docs" / "assets" / "ourocode-tui-demo.gif"
WIDTH = 1280
HEIGHT = 720
PAD = 34
LINE_HEIGHT = 22
FONT_SIZE = 16

PALETTE = {
    "bg": (250, 250, 249),
    "panel": (242, 242, 240),
    "stroke": (218, 218, 214),
    "text": (34, 34, 38),
    "muted": (92, 92, 99),
    "accent": (20, 102, 90),
    "warn": (153, 96, 35),
    "danger": (181, 42, 42),
    "yellow": (153, 96, 35),
}


def main() -> int:
    output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_OUTPUT
    output.parent.mkdir(parents=True, exist_ok=True)

    frames = load_frames()
    images = [render_frame(frame) for frame in frames]
    durations = [int(frame.get("duration_ms", 1000)) for frame in frames]

    images[0].save(
        output,
        save_all=True,
        append_images=images[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=2,
    )

    print(output.relative_to(ROOT))
    return 0


def load_frames():
    command = ["mix", "run", "--no-start", "scripts/tui_demo_frames.exs"]
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=True)
    return json.loads(extract_json(result.stdout))


def extract_json(output):
    start = output.find("[")
    end = output.rfind("]")
    if start == -1 or end == -1 or end < start:
        raise ValueError(f"could not find frame JSON in mix output: {output[:400]}")
    return output[start : end + 1]


def render_frame(frame):
    image = Image.new("RGB", (WIDTH, HEIGHT), PALETTE["bg"])
    draw = ImageDraw.Draw(image)
    font = load_font(FONT_SIZE)
    title_font = load_font(18)

    draw.rounded_rectangle(
        (18, 18, WIDTH - 18, HEIGHT - 18),
        radius=18,
        fill=PALETTE["panel"],
        outline=PALETTE["stroke"],
        width=1,
    )
    draw.ellipse((42, 40, 54, 52), fill=PALETTE["danger"])
    draw.ellipse((64, 40, 76, 52), fill=PALETTE["yellow"])
    draw.ellipse((86, 40, 98, 52), fill=PALETTE["accent"])
    draw.text((112, 36), "ourocode", fill=PALETTE["accent"], font=title_font)
    draw.text((222, 36), frame["title"], fill=PALETTE["muted"], font=title_font)

    y = 76
    for line in visible_lines(frame["text"]):
        draw.text((PAD, y), line, fill=line_color(line), font=font)
        y += LINE_HEIGHT

    return image


def visible_lines(text):
    lines = text.splitlines()
    max_lines = (HEIGHT - 104) // LINE_HEIGHT
    return lines[:max_lines]


def line_color(line):
    stripped = line.strip()
    if not stripped:
        return PALETTE["text"]
    if ">>" in line or "●" in line or "passed" in line or "ready" in line:
        return PALETTE["accent"]
    if any(token in line for token in ("INTERVIEW", "workspace", "Auto Workflow", "ooo structured")):
        return PALETTE["warn"]
    if stripped.startswith(("Actions", "Shortcuts", "Next")):
        return PALETTE["muted"]
    return PALETTE["text"]


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
