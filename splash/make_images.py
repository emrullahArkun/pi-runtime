"""Draws the images of the Plymouth theme (needs Pillow): python3 make_images.py

Sizes and colours match the boot view of wifi-setup/web/tv.html (ring 640, stroke 10,
mark 380 design pixels; --card and --primary from base.css).
"""

from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
RING, STROKE, MARK = 640, 10, 380
TRACK, ARC = (0xE6, 0xF5, 0xF3, 255), (0x0F, 0x7A, 0x70, 255)
FRAMES, OVERSAMPLE = 36, 3


def ring_frames():
    size, stroke = RING * OVERSAMPLE, STROKE * OVERSAMPLE
    box = [stroke // 2, stroke // 2, size - stroke // 2, size - stroke // 2]
    for i in range(FRAMES):
        image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(image)
        draw.arc(box, 0, 360, fill=TRACK, width=stroke)
        start = 270 + i * 360 // FRAMES
        draw.arc(box, start, start + 90, fill=ARC, width=stroke)
        image.resize((RING, RING), Image.LANCZOS).save(HERE / f"throbber-{i:04d}.png", optimize=True)


def watermark():
    mark = Image.open(HERE.parent / "wifi-setup" / "web" / "big-mark.png")
    size = (MARK, round(mark.height * MARK / mark.width))
    mark.resize(size, Image.LANCZOS).save(HERE / "watermark.png", optimize=True)


def prompt_images():
    # two-step refuses to load without its password prompt images; this kiosk never asks.
    for name in ("lock.png", "entry.png", "bullet.png"):
        Image.new("RGBA", (1, 1), (0, 0, 0, 0)).save(HERE / name)


if __name__ == "__main__":
    ring_frames()
    watermark()
    prompt_images()
