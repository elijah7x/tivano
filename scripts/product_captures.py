#!/usr/bin/env python3
"""Render development product screenshots from an isolated Debug app.

Run only when explicitly authorized to launch a capture instance. Mock conversations,
independent storage/defaults and a generated backdrop keep production data separate.
Raw stills, JSON framing sidecars and resized PNGs stay in build.noindex/product-captures;
nothing is imported into the application's asset catalog.

Needs Pillow: uv run --with Pillow scripts/product_captures.py
"""

import json
import pathlib
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
CAPTURES = ROOT / "build.noindex" / "product-captures"
DERIVED = ROOT / "build.noindex" / "product-captures-build"
APP = DERIVED / "Build/Products/Debug/Tivano Dev.app"
PROCESSED = CAPTURES / "processed"

WIDTH = 1320
HEIGHT = 824

# App window size in points for each still, matching the stage sizes in
# Tivano/App/Captures/ProductCaptures.swift (and ProductCaptures+Hydra.swift). Every
# still is a 16:10 rect around the window: the frame grown by 72 pt on every
# side, then widened/heightened to 1.6. The popover scenes (capture-pairs,
# capture-slider, capture-recipes) photograph the window unioned with the open popover
# (see Stage.productCaptureRect(including:)), so their PNGs are larger than the
# window-only rect below.
WINDOW_SIZES = {
    "capture-welcome": (1280, 800),
    "capture-hydra": (960, 600),
    "capture-pairs": (960, 600),
    "capture-slider": (960, 600),
    "capture-threads": (960, 600),
    "capture-recipes": (960, 600),
    "capture-panels": (1280, 800),
    "capture-theme-tokyoNight": (960, 600),
    "capture-theme-gruvbox": (960, 600),
    "capture-theme-catppuccinLatte": (960, 600),
    "capture-theme-rosePine": (960, 600),
}
THEME_ORDER = ["tokyoNight", "gruvbox", "catppuccinLatte", "rosePine"]


def window_box(name):
    """Return (rw, rh, mx, my, w, h): still rect and margins in points."""
    stem = name.removesuffix(".png")
    if stem not in WINDOW_SIZES:
        raise KeyError(f"No window size for {name}")
    w, h = WINDOW_SIZES[stem]
    rw, rh = w + 144, h + 144
    if rw / rh < 1.6:
        rw = round(rh * 1.6)
    else:
        rh = round(rw / 1.6)
    return (rw, rh, (rw - w) / 2, (rh - h) / 2, w, h)


def step(title):
    print(f"\n==> {title}", flush=True)


def build():
    step("Building Tivano (Debug)")
    if shutil.which("xcodegen"):
        subprocess.run(["xcodegen", "generate", "--quiet"], cwd=ROOT, check=True)
    elif not (ROOT / "Tivano.xcodeproj").exists():
        sys.exit("Install XcodeGen to generate Tivano.xcodeproj")
    result = subprocess.run([
        "xcodebuild", "-project", "Tivano.xcodeproj", "-scheme", "Tivano", "-configuration", "Debug",
        "-destination", "platform=macOS", "-derivedDataPath", str(DERIVED), "-skipPackagePluginValidation", "build",
    ], cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print("\n".join(line for line in result.stdout.splitlines() if "error:" in line))
        sys.exit("Build failed")


def capture():
    step("Capturing the product scenes")
    shutil.rmtree(CAPTURES, ignore_errors=True)
    CAPTURES.mkdir(parents=True)
    # Through LaunchServices, not the binary: an app launched from a shell is refused
    # activation, and the captures need the key window of the active app. Not waited on:
    # the run is force-killed at its budget, so a stall can never leave it running.
    marker = "website-captures " + str(CAPTURES)
    subprocess.run(["open", "-n", str(APP), "--args", "-AppleLanguages", "(en)", "--website-captures", str(CAPTURES)], check=True)
    deadline = time.time() + 630
    while time.time() < deadline:
        time.sleep(2)
        alive = subprocess.run(["pgrep", "-f", marker], capture_output=True, text=True).stdout.strip()
        if not alive:
            break
    else:
        subprocess.run(["pkill", "-9", "-f", marker])
        print("  the run overran its budget and was killed")
    log = CAPTURES / "run.log"
    if log.exists():
        print("  " + log.read_text().strip().splitlines()[-1])


def fit(image, width, height):
    """Centre-crop to the target aspect (a no-op when already exact, up to rounding),
    then resize to exactly width x height."""
    from PIL import Image
    if abs(image.width / image.height - width / height) > 1e-9:
        target = width / height
        if image.width / image.height > target:
            want = round(image.height * target)
            left = (image.width - want) // 2
            image = image.crop((left, 0, left + want, image.height))
        else:
            want = round(image.width / target)
            top = (image.height - want) // 2
            image = image.crop((0, top, image.width, top + want))
    return image.resize((width, height), Image.LANCZOS)


def write_image(name, image):
    PROCESSED.mkdir(parents=True, exist_ok=True)
    path = PROCESSED / f"{name}.png"
    image.save(path, "PNG")
    print(f"  {path.relative_to(ROOT)}")


def interior(name, inset=8):
    """The window's inside, `inset` points in from its edges: the screenshot card rounds its own
    corners, so a picture that still showed the window's corners would draw a second,
    tighter corner inside them.

    The app writes <name>.json beside each still with the still's rect and the window's
    place in it (top-left origin, points), and that is what is cut: a still framed
    around an open popover is wider than the window, so the window's size alone put
    the box in the wrong place. Older runs without the sidecar fall back to the size
    table, which is exact only for window-only stills."""
    from PIL import Image
    image = Image.open(CAPTURES / f"{name}.png").convert("RGB")
    sidecar = CAPTURES / f"{name}.json"
    if sidecar.exists():
        frames = json.loads(sidecar.read_text())
        _, _, rect_w, rect_h = frames["rect"]
        x, y, w, h = frames["window"]
        scale = image.width / rect_w
    else:
        rw, rh, x, y, w, h = window_box(name)
        scale = 2
    box = (round(scale * (x + inset)), round(scale * (y + inset)), round(scale * (x + w - inset)), round(scale * (y + h - inset)))
    return image.crop(box)


def focus_box(inner, focus, aspect=WIDTH / HEIGHT, min_share=0.55):
    """The 16:10 box (left, top, right, bottom) in points a page is cut to, inside the
    window's inside `inner`, around `focus` (x, y, w, h): the focus padded, grown to the
    aspect about its centre, never narrower than `min_share` of the inside's width, and
    shifted (never shrunk) to lie inside. With no focus, or a focus the inside cannot
    hold, the whole inside."""
    il, it, ir, ib = inner
    iw, ih = ir - il, ib - it
    if focus is None:
        return inner
    fx, fy, fw, fh = focus
    pad = max(40, 0.12 * max(fw, fh))
    w, h = fw + 2 * pad, fh + 2 * pad
    cx, cy = fx + fw / 2, fy + fh / 2
    if w / h < aspect:
        w = h * aspect
    else:
        h = w / aspect
    if w < iw * min_share:
        w = iw * min_share
        h = w / aspect
    if w > iw or h > ih:
        return inner
    left, top = cx - w / 2, cy - h / 2
    left = min(max(left, il), ir - w)
    top = min(max(top, it), ib - h)
    return (left, top, left + w, top + h)


def frame(name, inset=8):
    """The product screenshot: the window's inside, zoomed on the still's focus when the
    sidecar names one (see `focus_box`); `interior` otherwise."""
    from PIL import Image
    sidecar = CAPTURES / f"{name}.json"
    if not sidecar.exists():
        return interior(name, inset)
    image = Image.open(CAPTURES / f"{name}.png").convert("RGB")
    frames = json.loads(sidecar.read_text())
    _, _, rect_w, rect_h = frames["rect"]
    x, y, w, h = frames["window"]
    scale = image.width / rect_w
    inner = (x + inset, y + inset, x + w - inset, y + h - inset)
    focus = frames.get("focus")
    min_share = 0.45 if name == "capture-slider" else 0.55
    box = focus_box(inner, focus, min_share=min_share)
    if focus and box == inner:
        # A focus the window cannot hold (the cookbook's popover is taller than the
        # window it hangs from): cut around it within the whole still instead, so the
        # page shows the popover entire beside the window rather than clipped at its edge.
        box = focus_box((0, 0, rect_w, rect_h), focus, min_share=min_share)
    print(f"  {name}: {'focus' if focus and box != inner else 'whole window'} {tuple(round(v) for v in box)}")
    return image.crop(tuple(round(scale * v) for v in box))


def theme_mosaic():
    """The four theme windows' insides, two by two with a thin dark seam, for the screenshots."""
    from PIL import Image
    tiles = [interior(f"capture-theme-{theme}", inset=8) for theme in THEME_ORDER]
    gap = 6
    tile_w = (WIDTH - gap) // 2
    tile_h = (HEIGHT - gap) // 2
    mosaic = Image.new("RGB", (tile_w * 2 + gap, tile_h * 2 + gap), (16, 16, 20))
    for index, tile in enumerate(tiles):
        mosaic.paste(fit(tile, tile_w, tile_h), ((index % 2) * (tile_w + gap), (index // 2) * (tile_h + gap)))
    return mosaic


def encode():
    from PIL import Image
    step("Resizing screenshots")
    # The welcome page is its own scene: the whole window with the sidebar open, no
    # popover, so the first page is the overview and not the hero's close-up.
    for name, source in [("capture-welcome", "capture-welcome"), ("capture-hydra", "capture-hydra"), ("capture-pairs", "capture-pairs"),
                         ("capture-slider", "capture-slider"), ("capture-threads", "capture-threads"), ("capture-recipes", "capture-recipes"), ("capture-panels", "capture-panels")]:
        if not (CAPTURES / f"{source}.png").exists():
            sys.exit(f"The capture run wrote no {source}.png; see {CAPTURES / 'run.log'}")
        write_image(name, fit(frame(source), WIDTH, HEIGHT))
    write_image("capture-themes", fit(theme_mosaic(), WIDTH, HEIGHT))


if __name__ == "__main__":
    try:
        import PIL
    except ImportError:
        sys.exit("Pillow is required: uv run --with Pillow scripts/product_captures.py")
    build()
    capture()
    encode()
    print(f"\nReady: {PROCESSED}")
