#!/bin/sh
# Rasterise the keepsake faces and copy the scene SVGs into the app's asset catalog.
# Run final.py and scene_assets.py first. Needs Google Chrome (headless) for SVG to PNG.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../../../.." && pwd)
faces="$here/../early-supporter"
scene="$here/../scene"
assets="$root/Tivano/Resources/Assets.xcassets"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
size=384

png() { # svg out scale
  cp "$1" "$work/in.svg"
  printf '<html><body style="margin:0;background:transparent"><img src="in.svg" width="%s" height="%s"></body></html>' "$size" "$size" > "$work/in.html"
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --force-device-scale-factor="$3" --window-size="$size,$size" --screenshot="$2" "file://$work/in.html" >/dev/null 2>&1
}

raster_set() { # name light-svg [dark-svg]
  set_dir="$assets/$1.imageset"; rm -rf "$set_dir"; mkdir -p "$set_dir"
  images=""
  for scale in 1 2 3; do
    png "$2" "$set_dir/$1@${scale}x.png" "$scale"
    images="$images{\"filename\":\"$1@${scale}x.png\",\"idiom\":\"universal\",\"scale\":\"${scale}x\"},"
    if [ -n "${3:-}" ]; then
      png "$3" "$set_dir/$1-dark@${scale}x.png" "$scale"
      images="$images{\"appearances\":[{\"appearance\":\"luminosity\",\"value\":\"dark\"}],\"filename\":\"$1-dark@${scale}x.png\",\"idiom\":\"universal\",\"scale\":\"${scale}x\"},"
    fi
  done
  printf '{"images":[%s],"info":{"author":"xcode","version":1}}\n' "${images%,}" > "$set_dir/Contents.json"
}

vector_set() { # name
  set_dir="$assets/$1.imageset"; rm -rf "$set_dir"; mkdir -p "$set_dir"
  cp "$scene/$1-light.svg" "$scene/$1-dark.svg" "$set_dir/"
  printf '{"images":[{"filename":"%s-light.svg","idiom":"universal"},{"appearances":[{"appearance":"luminosity","value":"dark"}],"filename":"%s-dark.svg","idiom":"universal"}],"info":{"author":"xcode","version":1},"properties":{"preserves-vector-representation":true,"template-rendering-intent":"original"}}\n' "$1" "$1" > "$set_dir/Contents.json"
}

raster_set keepsake-early-supporter-front "$faces/front-lit.svg" "$faces/front-lit-dark.svg"
raster_set keepsake-early-supporter-back "$faces/back-lit.svg" "$faces/back-lit-dark.svg"
raster_set keepsake-early-supporter-unlit "$faces/front-unlit.svg"
for name in keepsake-branch keepsake-leaf keepsake-backdrop; do vector_set "$name"; done
echo "Keepsake assets written to $assets"
