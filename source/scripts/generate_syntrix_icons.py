"""Generate SYNTRIX's SVG and Windows ICO assets using Pillow."""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SIZES = range(1, 257)
SHAPES = (
    ("#111D33", ((3, 0), (13, 0), (16, 3), (16, 13), (13, 16), (3, 16), (0, 13), (0, 3))),
    ("#66C7FF", ((3, 5), (5, 3), (12, 3), (12, 7), (9, 7), (9, 5), (6, 5), (4, 7), (3, 7))),
    ("#FFFFFF", ((13, 11), (11, 13), (4, 13), (4, 9), (7, 9), (7, 11), (10, 11), (12, 9), (13, 9))),
)


def main():
    polygons = []
    image = Image.new("RGBA", (512, 512))
    draw = ImageDraw.Draw(image)
    for color, points in SHAPES:
        geometry = " ".join(f"{x},{y}" for x, y in points)
        polygons.append(f'  <polygon fill="{color}" points="{geometry}"/>')
        draw.polygon([(x * 32, y * 32) for x, y in points], fill=color)

    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">\n'
        '  <title>SYNTRIX Remote</title>\n' + "\n".join(polygons) + "\n</svg>\n"
    )
    (ROOT / "flutter/assets/icon.svg").write_text(svg, encoding="utf-8", newline="\n")
    for filename in (
        "res/icon.ico",
        "res/tray-icon.ico",
        "flutter/windows/runner/resources/app_icon.ico",
    ):
        image.save(ROOT / filename, sizes=[(size, size) for size in SIZES])


if __name__ == "__main__":
    main()
