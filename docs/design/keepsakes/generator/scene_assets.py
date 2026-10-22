"""Write the keepsake page's scene art (branch, loose leaf, backdrop) as SVG.

Drawn in the approved mockup's 638 x 420 card: the keepsake's cord attaches at
x = 0.44, y = 133/420 of the card, and the branch sways around (0, 133/420).
"""
import math
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / 'scene'
INK = {'light': '#647e6e', 'dark': '#a2bbaa'}
DOTS = {'light': '#71856a', 'dark': '#c0d4b5'}
MIDRIB = {'light': '#edf2e9', 'dark': '#dce8d9'}
BRANCH = ('M-12 141 C26 136 57 134 88 130 L92 128 L96 130 C124 123 155 124 182 126 L188 125 L191 127 C220 130 247 131 270 131 Q281 132 292 131 C314 128 337 133 353 135 L358 134 L361 136 Q394 139 435 132 Q398 143 360 139 L355 140 L351 138 C330 137 313 132 292 135 Q281 134 270 135 C243 136 217 133 191 132 L186 133 L181 131 C150 129 124 130 97 135 L92 137 L88 136 C54 142 23 143 -12 150 Z',
          'M89 133 Q101 116 103 104 L102 88 Q105 96 106 101 Q110 97 118 93 Q112 100 107 105 Q104 122 94 135 Z M207 130 Q221 117 229 105 L237 91 Q234 102 230 109 Q237 108 245 108 Q237 111 228 113 Q223 124 211 133 Z M350 136 Q365 150 380 155 Q364 154 352 140 Z')
PENCIL = 'M-5 152 Q55 142 92 140 Q138 130 179 134 M195 135 Q237 139 267 138 Q282 137 297 138 Q323 135 343 140'
LEAVES = 'M105 104 Q88 102 91 88 Q103 89 105 104 M118 93 Q117 77 131 76 Q131 87 118 93 M231 104 Q223 90 237 85 Q243 98 231 104 M380 155 Q394 147 402 160 Q389 166 380 155'
RIBS = 'M104 102 Q98 97 94 92 M119 91 Q125 85 128 80 M232 102 Q235 95 236 89 M383 155 Q390 158 398 159'
SKETCH = ('M-12 331 Q171 298 320 318 T661 292 M21 338 Q204 313 343 326 M116 70 Q278 27 443 102 M123 73 Q261 39 347 67 M482 265 Q448 333 507 396 M502 263 Q476 333 527 373',
          'M43 273 L99 279 M72 251 L69 304 M377 56 L391 84')
WIND = 'M339 197 Q390 177 443 188 T558 178 M400 241 Q455 216 499 223 T618 208 M464 295 Q522 270 597 279'
LEAF = 'M401 188 Q408 172 423 179 Q418 193 401 188 M402 187 L419 180'
CARD = 'viewBox="0 0 638 420" width="638" height="420"'
ROUND = 'stroke-linecap="round" stroke-linejoin="round"'


def svg(body, box=CARD):
    return f'<svg xmlns="http://www.w3.org/2000/svg" {box}>{body}</svg>\n'


def write(name, mode, text):
    folder = OUT
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f'{name}-{mode}.svg').write_text(text, encoding='utf-8')


for mode in ('light', 'dark'):
    ink = INK[mode]
    branch = (f'<g fill="{ink}" opacity=".76">' + ''.join(f'<path d="{d}"/>' for d in BRANCH) + '</g>'
              f'<path d="{PENCIL}" fill="none" stroke="{ink}" stroke-width=".6" opacity=".19" {ROUND}/>'
              f'<path d="{LEAVES}" fill="{ink}" opacity=".65"/>'
              f'<path d="{RIBS}" fill="none" stroke="{MIDRIB[mode]}" stroke-width=".65" opacity=".6" {ROUND}/>')
    write('keepsake-branch', mode, svg(branch))
    leaf = (f'<path d="{LEAF}" fill="{ink}" fill-opacity=".14" stroke="{ink}" stroke-width=".75" opacity=".35" {ROUND}/>')
    write('keepsake-leaf', mode, svg(leaf, 'viewBox="399 169 26 26" width="26" height="26"'))
    dots = []
    for y in range(168, 420, 10):
        for x in range(198, 638, 10):
            strength = max(0, 1 - math.hypot((638 - x) / 440, (420 - y) / 300))
            alpha = (.12 + strength * .2) * max(0, 1 - math.hypot((638 - x) / 542, (420 - y) / 357) / .8) * .65
            if alpha > .01:
                dots.append(f'<circle cx="{x}" cy="{y}" r="{.3 + strength * .85:.2f}" opacity="{alpha:.3f}"/>')
    backdrop = (f'<g fill="none" stroke="{ink}" stroke-width=".65" opacity=".12" {ROUND}>' + ''.join(f'<path d="{d}"/>' for d in SKETCH) + '</g>'
                f'<path d="{WIND}" fill="none" stroke="{ink}" stroke-width=".7" opacity=".13" {ROUND}/>'
                f'<g fill="{DOTS[mode]}">' + ''.join(dots) + '</g>')
    write('keepsake-backdrop', mode, svg(backdrop))
