"""Generate App Store promotional screenshots (6.5-inch: 1242x2688)."""

from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os

# Config
OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))
WIDTH, HEIGHT = 1242, 2688

FONT_BOLD = "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
FONT_REGULAR = "/System/Library/Fonts/ヒラギノ角ゴシック W4.ttc"

SCREENSHOTS = [
    {
        "src": os.path.expanduser("~/Downloads/IMG_0257.PNG"),
        "title": "全科目の課題を\nひと目で確認",
        "subtitle": "緊急度別に色分け表示",
        "bg_top": (41, 98, 255),     # Blue
        "bg_bottom": (88, 166, 255),
        "output": "01_assignment_list.png",
    },
    {
        "src": os.path.expanduser("~/Downloads/IMG_0258.PNG"),
        "title": "通知タイミングを\n自由にカスタマイズ",
        "subtitle": "10分前〜3日前から最大5個設定",
        "bg_top": (109, 58, 230),    # Purple
        "bg_bottom": (170, 120, 255),
        "output": "02_settings.png",
    },
]


def make_gradient(width, height, top_color, bottom_color):
    img = Image.new("RGB", (width, height))
    for y in range(height):
        ratio = y / height
        r = int(top_color[0] + (bottom_color[0] - top_color[0]) * ratio)
        g = int(top_color[1] + (bottom_color[1] - top_color[1]) * ratio)
        b = int(top_color[2] + (bottom_color[2] - top_color[2]) * ratio)
        for x in range(width):
            img.putpixel((x, y), (r, g, b))
    return img


def make_gradient_fast(width, height, top_color, bottom_color):
    import numpy as np

    arr = np.zeros((height, width, 3), dtype=np.uint8)
    for c in range(3):
        arr[:, :, c] = np.linspace(top_color[c], bottom_color[c], height, dtype=np.uint8)[
            :, None
        ]
    return Image.fromarray(arr)


def add_rounded_corners(img, radius):
    mask = Image.new("L", img.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle([(0, 0), img.size], radius=radius, fill=255)
    result = Image.new("RGBA", img.size, (0, 0, 0, 0))
    result.paste(img, mask=mask)
    return result


def add_shadow(img, offset=(0, 10), blur_radius=30, opacity=80):
    shadow = Image.new("RGBA", (img.width + blur_radius * 2, img.height + blur_radius * 2), (0, 0, 0, 0))
    shadow_inner = Image.new("RGBA", img.size, (0, 0, 0, opacity))
    # Use alpha from the original image as shadow mask
    if img.mode == "RGBA":
        shadow_inner.putalpha(img.split()[3].point(lambda p: min(p, opacity)))
    shadow.paste(shadow_inner, (blur_radius + offset[0], blur_radius + offset[1]))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur_radius))
    return shadow, blur_radius


def generate_screenshot(config):
    try:
        make_grad = make_gradient_fast
    except ImportError:
        make_grad = make_gradient

    # Create gradient background
    bg = make_grad(WIDTH, HEIGHT, config["bg_top"], config["bg_bottom"]).convert("RGBA")
    draw = ImageDraw.Draw(bg)

    # Draw title text
    title_font = ImageFont.truetype(FONT_BOLD, 88)
    subtitle_font = ImageFont.truetype(FONT_REGULAR, 48)

    # Title position - centered near top
    title_y = 180
    for line in config["title"].split("\n"):
        bbox = title_font.getbbox(line)
        line_w = bbox[2] - bbox[0]
        draw.text(((WIDTH - line_w) / 2, title_y), line, fill="white", font=title_font)
        title_y += 110

    # Subtitle
    subtitle_y = title_y + 30
    sub_bbox = subtitle_font.getbbox(config["subtitle"])
    sub_w = sub_bbox[2] - sub_bbox[0]
    draw.text(
        ((WIDTH - sub_w) / 2, subtitle_y),
        config["subtitle"],
        fill=(255, 255, 255, 200),
        font=subtitle_font,
    )

    # Load and resize screenshot to fit nicely
    screenshot = Image.open(config["src"]).convert("RGBA")

    # Target: screenshot should be ~75% of canvas width, positioned in center-bottom
    target_w = int(WIDTH * 0.72)
    scale = target_w / screenshot.width
    target_h = int(screenshot.height * scale)
    screenshot = screenshot.resize((target_w, target_h), Image.LANCZOS)

    # Add rounded corners
    corner_radius = 40
    screenshot = add_rounded_corners(screenshot, corner_radius)

    # Add shadow
    shadow, blur_r = add_shadow(screenshot, offset=(0, 15), blur_radius=40, opacity=60)

    # Position: horizontally centered, bottom-aligned (slightly overflowing)
    ss_x = (WIDTH - target_w) // 2
    ss_y = HEIGHT - target_h + int(target_h * 0.08)  # 8% overflow at bottom

    shadow_x = ss_x - blur_r
    shadow_y = ss_y - blur_r
    bg.paste(shadow, (shadow_x, shadow_y), shadow)
    bg.paste(screenshot, (ss_x, ss_y), screenshot)

    # Save as RGB (no alpha channel — required by App Store / Google Play)
    output_path = os.path.join(OUTPUT_DIR, config["output"])
    bg.convert("RGB").save(output_path, "PNG")
    print(f"Saved: {output_path} ({WIDTH}x{HEIGHT})")


if __name__ == "__main__":
    for config in SCREENSHOTS:
        generate_screenshot(config)
    print("Done!")
