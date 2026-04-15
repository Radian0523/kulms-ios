"""Generate App Store promotional screenshots for iPad (2048x2732)."""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import numpy as np
import os

OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))
WIDTH, HEIGHT = 2048, 2732

FONT_BOLD = "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
FONT_REGULAR = "/System/Library/Fonts/ヒラギノ角ゴシック W4.ttc"

SCREENSHOTS = [
    {
        "src": os.path.expanduser("~/Downloads/Gemini_Generated_Image_9cgrz59cgrz59cgr.png"),
        "title": "iPadの大画面で\n課題をまとめて確認",
        "subtitle": "緊急度別に色分け表示",
        "bg_top": (41, 98, 255),
        "bg_bottom": (88, 166, 255),
        "output": "ipad_01_assignment_list.png",
    },
]


def make_gradient(width, height, top_color, bottom_color):
    arr = np.zeros((height, width, 3), dtype=np.uint8)
    for c in range(3):
        arr[:, :, c] = np.linspace(top_color[c], bottom_color[c], height, dtype=np.uint8)[:, None]
    return Image.fromarray(arr)


def add_rounded_corners(img, radius, bg_color):
    """Add rounded corners, filling transparent areas with bg_color."""
    rgba = img.convert("RGBA")
    mask = Image.new("L", rgba.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([(0, 0), rgba.size], radius=radius, fill=255)
    # Composite onto solid background
    solid = Image.new("RGBA", rgba.size, bg_color + (255,))
    result = Image.new("RGBA", rgba.size, (0, 0, 0, 0))
    result.paste(solid, (0, 0))
    result.paste(rgba, mask=mask)
    # Re-apply mask so corners are transparent for shadow compositing
    result.putalpha(mask)
    return result


def generate_screenshot(config):
    bg = make_gradient(WIDTH, HEIGHT, config["bg_top"], config["bg_bottom"]).convert("RGB")
    draw = ImageDraw.Draw(bg)

    title_font = ImageFont.truetype(FONT_BOLD, 120)
    subtitle_font = ImageFont.truetype(FONT_REGULAR, 64)

    # Title
    title_y = 200
    for line in config["title"].split("\n"):
        bbox = title_font.getbbox(line)
        line_w = bbox[2] - bbox[0]
        draw.text(((WIDTH - line_w) / 2, title_y), line, fill="white", font=title_font)
        title_y += 150

    # Subtitle
    subtitle_y = title_y + 40
    sub_bbox = subtitle_font.getbbox(config["subtitle"])
    sub_w = sub_bbox[2] - sub_bbox[0]
    draw.text(
        ((WIDTH - sub_w) / 2, subtitle_y),
        config["subtitle"],
        fill=(230, 230, 255),
        font=subtitle_font,
    )

    # Load screenshot
    screenshot = Image.open(config["src"]).convert("RGBA")

    # Scale to ~85% of canvas width (landscape screenshot on portrait canvas)
    target_w = int(WIDTH * 0.85)
    scale = target_w / screenshot.width
    target_h = int(screenshot.height * scale)
    screenshot = screenshot.resize((target_w, target_h), Image.LANCZOS)

    # Rounded corners with a neutral bg color for the corner fill
    corner_radius = 40
    screenshot = add_rounded_corners(screenshot, corner_radius, (245, 245, 245))

    # Position: centered, in the lower portion
    ss_x = (WIDTH - target_w) // 2
    ss_y = subtitle_y + 140

    # Draw shadow manually (solid dark rectangle, blurred)
    shadow_offset = 15
    shadow_blur = 40
    shadow_layer = Image.new("RGB", bg.size, (0, 0, 0))
    shadow_mask = Image.new("L", bg.size, 0)
    shadow_draw = ImageDraw.Draw(shadow_mask)
    shadow_draw.rounded_rectangle(
        [(ss_x + 4, ss_y + shadow_offset), (ss_x + target_w - 4, ss_y + target_h + shadow_offset)],
        radius=corner_radius,
        fill=50,
    )
    shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(shadow_blur))
    bg = Image.composite(shadow_layer, bg, shadow_mask)

    # Paste screenshot (use alpha as mask for rounded corners)
    bg.paste(screenshot, (ss_x, ss_y), screenshot)

    # Save as RGB
    output_path = os.path.join(OUTPUT_DIR, config["output"])
    bg.convert("RGB").save(output_path, "PNG")
    print(f"Saved: {output_path} ({WIDTH}x{HEIGHT})")


if __name__ == "__main__":
    for config in SCREENSHOTS:
        generate_screenshot(config)
    print("Done!")
