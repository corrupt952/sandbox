#!/usr/bin/env python3
"""Compare the PNGs produced by render.sh.

    python3 compare.py            # report + out/stack-<name>.png
    python3 compare.py --docs     # also refresh the committed docs/ images

Prints the output size of every renderer (does it honour the viewBox?) and
the pixel difference between each pair, then writes out/stack-<name>.png
with the renderers stacked vertically for eyeballing.

--docs additionally writes a 256-colour quantized copy into docs/, which is
what README.md embeds. Quantizing keeps those committed images at roughly a
third of the size with no visible loss on flat-colour diagrams like these.
"""
import sys
from pathlib import Path

try:
    from PIL import Image, ImageChops, ImageDraw
except ImportError:
    sys.exit("Pillow is required. Run 'nix develop' first, or pip install pillow.")

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "out"
DOCS = ROOT / "docs"
RENDERERS = ["resvg", "sips", "chrome"]
THRESHOLD = 16  # per-channel difference below this counts as antialiasing noise
DOCS_COLORS = 256


def diff_ratio(a, b):
    """Share of pixels differing by more than THRESHOLD, in percent."""
    if a.size != b.size:
        return None
    d = ImageChops.difference(a, b)
    # getdata() is deprecated in Pillow 12; get_flattened_data() replaces it.
    px = d.get_flattened_data() if hasattr(d, "get_flattened_data") else d.getdata()
    return sum(1 for v in px if max(v) > THRESHOLD) / (a.size[0] * a.size[1]) * 100


def stack(images, path):
    label_h = 22
    width = max(img.size[0] for img, _ in images)
    canvas = Image.new("RGB", (width, sum(i.size[1] + label_h for i, _ in images)), "white")
    y = 0
    for img, label in images:
        ImageDraw.Draw(canvas).text((6, y + 5), label, fill="#c00")
        canvas.paste(img, (0, y + label_h))
        y += img.size[1] + label_h
    canvas.save(path)


def main():
    write_docs = "--docs" in sys.argv[1:]
    figures = sorted(ROOT.glob("figures/*.svg"))
    if not figures:
        sys.exit("No figures found.")
    if not OUT.exists():
        sys.exit("out/ not found. Run ./render.sh first.")
    if write_docs:
        DOCS.mkdir(exist_ok=True)

    for svg in figures:
        name = svg.stem
        loaded = []
        for r in RENDERERS:
            p = OUT / f"{name}.{r}.png"
            if p.exists():
                loaded.append((Image.open(p).convert("RGB"), r))

        if not loaded:
            print(f"{name}: no output found, skipping")
            continue

        print(f"\n== {name}  (viewBox {declared_size(svg)})")
        for img, r in loaded:
            print(f"   {r:<7} {img.size[0]}x{img.size[1]}")

        for i in range(len(loaded)):
            for j in range(i + 1, len(loaded)):
                (a, ra), (b, rb) = loaded[i], loaded[j]
                d = diff_ratio(a, b)
                if d is None:
                    print(f"   {ra} vs {rb}: size mismatch, not comparable")
                else:
                    print(f"   {ra} vs {rb}: {d:.1f}% of pixels differ")

        out_path = OUT / f"stack-{name}.png"
        stack(loaded, out_path)
        print(f"   -> {out_path.relative_to(ROOT)}")

        if write_docs:
            docs_path = DOCS / f"{name}.png"
            quantized = Image.open(out_path).convert("RGB").quantize(
                colors=DOCS_COLORS, method=Image.Quantize.MEDIANCUT
            )
            quantized.save(docs_path, optimize=True)
            kb = docs_path.stat().st_size / 1024
            print(f"   -> {docs_path.relative_to(ROOT)} ({kb:.0f} KB)")


def declared_size(svg):
    import re
    src = svg.read_text(encoding="utf-8", errors="replace")
    m = re.search(r'viewBox="0 0 (\d+) (\d+)"', src)
    return f"{m.group(1)}x{m.group(2)}" if m else "unknown"


if __name__ == "__main__":
    main()
